//
//  SketchOffload.m
//  MinisApp
//
//  Native offload handler for `rovie-sketch` and `apple-sketch`.
//  Subcommands: explain, add-step, open, snapshot, voices, clear
//

#import "SketchOffload.h"
#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#import "Minis-Swift.h"
#include "kernel/native_offload.h"
#include <unistd.h>

static NSString *const TOOL_NAME = @"rovie-sketch";

static NSString *const HELP_TEXT =
    @"rovie-sketch / apple-sketch - Interactive PencilKit Sketch Pad + Kokoro-82M Voice Tutor\n"
     "\n"
     "USAGE:\n"
     "  rovie-sketch <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  explain       Open the PencilKit Sketch Pad, animate drawing steps, and speak each step with Kokoro-82M\n"
     "  add-step      Append a new drawing + spoken step to the open Sketch Pad\n"
     "  open          Open an interactive blank PencilKit Sketch Pad\n"
     "  snapshot      Export the current PencilKit canvas (AI + user strokes) to a PNG image\n"
     "  voices        List available Kokoro-82M voice presets and offline status\n"
     "  clear         Clear all strokes on the Sketch Pad\n"
     "\n"
     "EXPLAIN / ADD-STEP OPTIONS:\n"
     "  --file <path>      Path to JSON file containing the scene (or step)\n"
     "  --json '<string>'  Inline JSON string (or pipe JSON via stdin)\n"
     "  --voice <id>       Kokoro voice id: af_heart, af_bella, af_nicole, am_adam, am_michael, bf_emma, bm_george\n"
     "\n"
     "SNAPSHOT OPTIONS:\n"
     "  --output <path>    Output PNG path (default: /var/minis/offloads/sketch_<ts>.png)\n"
     "\n"
     "SCENE JSON FORMAT (0..1000 normalized canvas coordinates):\n"
     "  {\n"
     "    \"title\": \"How OAuth 2.0 Works\",\n"
     "    \"voice\": \"af_heart\",\n"
     "    \"steps\": [\n"
     "      {\n"
     "        \"title\": \"1. Authorization Request\",\n"
     "        \"speak\": \"First, the client redirects the user to the authorization server.\",\n"
     "        \"elements\": [\n"
     "          {\"type\":\"box\", \"x\":100, \"y\":150, \"w\":260, \"h\":100, \"color\":\"#2563EB\", \"label\":\"Client App\"},\n"
     "          {\"type\":\"arrow\", \"x1\":360, \"y1\":200, \"x2\":560, \"y2\":200, \"color\":\"#10B981\", \"label\":\"/authorize\"},\n"
     "          {\"type\":\"box\", \"x\":560, \"y\":150, \"w\":280, \"h\":100, \"color\":\"#8B5CF6\", \"label\":\"Auth Server\"}\n"
     "        ]\n"
     "      }\n"
     "    ]\n"
     "  }\n"
     "\n"
     "SUPPORTED ELEMENT TYPES:\n"
     "  box, circle, arrow, line, curve (points:[[x,y],...]), highlight, underline, text\n";

static NSString *read_json_input(int argc, char **argv, int stdin_fd) {
    NSString *jsonArg = noff_find_arg(argc, argv, "--json");
    if (jsonArg.length > 0) return jsonArg;

    NSString *fileArg = noff_find_arg(argc, argv, "--file") ?: noff_find_arg(argc, argv, "--input");
    if (fileArg.length > 0) {
        NSString *hostPath = noff_resolve_host_path(fileArg) ?: fileArg;
        NSString *contents = [NSString stringWithContentsOfFile:hostPath encoding:NSUTF8StringEncoding error:nil];
        if (contents.length > 0) return contents;
    }

    NSString *fromStdin = noff_read_stdin(stdin_fd);
    if (fromStdin.length > 0) return fromStdin;

    return nil;
}

static int cmd_open(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *title = noff_find_arg(argc, argv, "--title");
    NSString *voice = noff_find_arg(argc, argv, "--voice");

    __block NSDictionary *resData = nil;
    __block NSString *errMsg = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    noff_dispatch_main_sync(^id{
        [SketchOffloadBridge openEmptySketchPadWithTitle:title
                                                   voice:voice
                                              completion:^(NSDictionary *data, NSString *err) {
            resData = data;
            errMsg = err;
            dispatch_semaphore_signal(sem);
        }];
        return nil;
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    if (errMsg) {
        noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, @"open", NOFF_ERR_INTERNAL_ERROR, errMsg), compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"open", resData ?: @{}), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_explain(int argc, char **argv, int stdin_fd, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *jsonStr = read_json_input(argc, argv, stdin_fd);
    if (!jsonStr.length) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"explain",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: pass scene JSON via --file <path>, --json '<json>', or stdin.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *voice = noff_find_arg(argc, argv, "--voice");
    __block NSDictionary *resData = nil;
    __block NSString *errMsg = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    noff_dispatch_main_sync(^id{
        [SketchOffloadBridge explainWithJSON:jsonStr
                               voiceOverride:voice
                                  completion:^(NSDictionary *data, NSString *err) {
            resData = data;
            errMsg = err;
            dispatch_semaphore_signal(sem);
        }];
        return nil;
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    if (errMsg) {
        noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, @"explain", NOFF_ERR_INVALID_ARGS, errMsg), compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"explain", resData ?: @{}), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_add_step(int argc, char **argv, int stdin_fd, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *jsonStr = read_json_input(argc, argv, stdin_fd);
    if (!jsonStr.length) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"add-step",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: pass step JSON via --file <path>, --json '<json>', or stdin.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    __block NSDictionary *resData = nil;
    __block NSString *errMsg = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    noff_dispatch_main_sync(^id{
        [SketchOffloadBridge addStepWithJSON:jsonStr
                                  completion:^(NSDictionary *data, NSString *err) {
            resData = data;
            errMsg = err;
            dispatch_semaphore_signal(sem);
        }];
        return nil;
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    if (errMsg) {
        noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, @"add-step", NOFF_ERR_INVALID_ARGS, errMsg), compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"add-step", resData ?: @{}), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_snapshot(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *guestOutput = noff_find_arg(argc, argv, "--output");
    if (!guestOutput.length) {
        long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
        guestOutput = [NSString stringWithFormat:@"/var/minis/offloads/sketch_%lld.png", ts];
    }
    NSString *hostOutput = noff_resolve_host_path(guestOutput) ?: guestOutput;

    __block NSDictionary *resData = nil;
    __block NSString *errMsg = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    noff_dispatch_main_sync(^id{
        [SketchOffloadBridge captureSnapshotToHostPath:hostOutput
                                             guestPath:guestOutput
                                            completion:^(NSDictionary *data, NSString *err) {
            resData = data;
            errMsg = err;
            dispatch_semaphore_signal(sem);
        }];
        return nil;
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    if (errMsg) {
        noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, @"snapshot", NOFF_ERR_INTERNAL_ERROR, errMsg), compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"snapshot", resData ?: @{}), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_voices(int stdout_fd, BOOL compact, BOOL quiet) {
    __block NSDictionary *resData = nil;
    noff_dispatch_main_sync(^id{
        resData = [SketchOffloadBridge listVoices];
        return nil;
    });
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"voices", resData ?: @{}), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_clear(int stdout_fd, BOOL compact, BOOL quiet) {
    __block NSDictionary *resData = nil;
    noff_dispatch_main_sync(^id{
        resData = [SketchOffloadBridge clearCanvas];
        return nil;
    });
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"clear", resData ?: @{}), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int sketch_handler(int argc, char **argv,
                          int stdin_fd, int stdout_fd, int stderr_fd) {
    @autoreleasepool {
        if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
            noff_emit_help(stderr_fd, HELP_TEXT);
            return NOFF_EXIT_SUCCESS;
        }

        BOOL compact = noff_has_flag(argc, argv, "--compact");
        BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

        NSString *subcmd = noff_get_subcommand(argc, argv) ?: @"open";

        if ([subcmd isEqualToString:@"explain"])   return cmd_explain(argc, argv, stdin_fd, stdout_fd, stderr_fd, compact, quiet);
        if ([subcmd isEqualToString:@"add-step"])  return cmd_add_step(argc, argv, stdin_fd, stdout_fd, stderr_fd, compact, quiet);
        if ([subcmd isEqualToString:@"open"])      return cmd_open(argc, argv, stdout_fd, compact, quiet);
        if ([subcmd isEqualToString:@"snapshot"])  return cmd_snapshot(argc, argv, stdout_fd, compact, quiet);
        if ([subcmd isEqualToString:@"voices"])    return cmd_voices(stdout_fd, compact, quiet);
        if ([subcmd isEqualToString:@"clear"])     return cmd_clear(stdout_fd, compact, quiet);

        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                             NOFF_ERR_INVALID_ARGS,
                                             [NSString stringWithFormat:@"Unknown command '%@'. Valid commands: explain, add-step, open, snapshot, voices, clear.", subcmd]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
}

void sketch_offload_register(void) {
    int err1 = native_offload_add_handler("rovie-sketch", sketch_handler);
    int err2 = native_offload_add_handler("apple-sketch", sketch_handler);

    if (err1 == 0 || err2 == 0) {
        noff_ensure_guest_stub("/usr/local/bin/rovie-sketch");
        noff_ensure_guest_stub("/usr/local/bin/apple-sketch");
        NSLog(@"NativeOffloads: rovie-sketch & apple-sketch handlers registered");
    } else {
        NSLog(@"NativeOffloads: failed to register rovie-sketch handler (err=%d)", err1);
    }
}

