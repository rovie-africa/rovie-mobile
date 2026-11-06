//
//  CameraOffload.m
//  MinisApp
//
//  Native offload handler for `apple-camera` and `rovie-camera` — AVCapture photo capture.
//  Subcommands: snap (or capture), devices (or list), status
//

#import "CameraOffload.h"
#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#import "Minis-Swift.h"
#include "kernel/native_offload.h"
#include <unistd.h>

static NSString *const TOOL_NAME = @"apple-camera";

static NSString *const HELP_TEXT =
    @"apple-camera / rovie-camera - Capture photos using the device camera\n"
     "\n"
     "USAGE:\n"
     "  apple-camera <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  snap, capture    Capture a still photo with AVCaptureSession\n"
     "  devices, list    List available camera hardware devices\n"
     "  status           Check camera authorization permission status\n"
     "\n"
     "SNAP OPTIONS:\n"
     "  --front          Use the front (selfie / TrueDepth) camera\n"
     "  --back           Use the back (rear wide-angle) camera (default)\n"
     "  --flash <mode>   Flash mode: off (default), on, auto\n"
     "  --output <path>  Target output file path (default: /var/minis/offloads/camera_<ts>.jpg)\n"
     "\n"
     "COMMON OPTIONS:\n"
     "  --help, -h       Show this help message\n"
     "  --compact        Minimize JSON output (single line)\n"
     "  -q, --quiet      Output only the data field without envelope\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-camera snap --back --output /var/minis/offloads/meter.jpg\n"
     "  apple-camera snap --front\n"
     "  apple-camera devices\n"
     "  apple-camera status\n";

static int cmd_status(int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *status = [CameraOffloadBridge authorizationStatus];
    BOOL ok = [status isEqualToString:@"authorized"];
    NSDictionary *dict = @{
        @"status": status,
        @"authorized": @(ok)
    };
    NSDictionary *env = noff_json_envelope(TOOL_NAME, @"status", dict);
    noff_emit_json(stdout_fd, env, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_devices(int stdout_fd, BOOL compact, BOOL quiet) {
    NSArray *devices = [CameraOffloadBridge listDevices];
    NSDictionary *env = noff_json_envelope(TOOL_NAME, @"devices", devices);
    noff_emit_json(stdout_fd, env, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_snap(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *position = @"back";
    if (noff_has_flag(argc, argv, "--front")) {
        position = @"front";
    } else if (noff_has_flag(argc, argv, "--back")) {
        position = @"back";
    }

    NSString *flash = noff_find_arg(argc, argv, "--flash") ?: @"off";
    NSString *guestOutput = noff_find_arg(argc, argv, "--output");

    if (!guestOutput || guestOutput.length == 0) {
        long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
        guestOutput = [NSString stringWithFormat:@"/var/minis/offloads/camera_%lld.jpg", ts];
    }

    // Resolve guest path (Linux container) to host iOS path
    NSString *hostOutput = noff_resolve_host_path(guestOutput);
    if (!hostOutput) {
        hostOutput = guestOutput;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *captureResult = nil;

    [CameraOffloadBridge capturePhotoWithPosition:position
                                        flashMode:flash
                                       outputPath:hostOutput
                                       completion:^(NSDictionary *result) {
        captureResult = result;
        dispatch_semaphore_signal(sem);
    }];

    // Wait up to 20 seconds for camera capture
    intptr_t waitRes = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    if (waitRes != 0 || !captureResult) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"snap", @"timeout", @"Camera capture timed out after 20 seconds.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_NOT_AVAILABLE;
    }

    BOOL ok = [captureResult[@"ok"] boolValue];
    if (!ok) {
        NSString *code = captureResult[@"error"] ?: @"capture_failed";
        NSString *msg = captureResult[@"message"] ?: @"Failed to capture photo.";
        NSDictionary *err = noff_json_error(TOOL_NAME, @"snap", code, msg);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_NOT_AVAILABLE;
    }

    // Remap path in result to guest path so caller sees its requested path
    NSMutableDictionary *data = [captureResult mutableCopy];
    data[@"guestPath"] = guestOutput;

    NSDictionary *env = noff_json_envelope(TOOL_NAME, @"snap", data);
    noff_emit_json(stdout_fd, env, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int camera_handler(int argc, char **argv,
                          int stdin_fd, int stdout_fd, int stderr_fd) {
    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    if (argc < 2 || noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_ERROR;
    }

    if ([subcmd isEqualToString:@"snap"] || [subcmd isEqualToString:@"capture"]) {
        return cmd_snap(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"devices"] || [subcmd isEqualToString:@"list"]) {
        return cmd_devices(stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"status"]) {
        return cmd_status(stdout_fd, compact, quiet);
    } else {
        NSString *msg = [NSString stringWithFormat:@"Unknown camera subcommand '%@'. Use --help for usage.", subcmd];
        NSDictionary *err = noff_json_error(TOOL_NAME, subcmd, @"unknown_command", msg);
        noff_emit_json(stderr_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
}

void camera_offload_register(void) {
    int err1 = native_offload_add_handler("apple-camera", camera_handler);
    int err2 = native_offload_add_handler("rovie-camera", camera_handler);

    if (err1 == 0 || err2 == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-camera");
        noff_ensure_guest_stub("/usr/local/bin/rovie-camera");
        NSLog(@"NativeOffloads: apple-camera & rovie-camera handlers registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-camera handler (err=%d)", err1);
    }
}

