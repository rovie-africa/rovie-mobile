//
//  ActivityOffload.m
//  MinisApp
//
//  Native offload handler for `apple-activity`.
//  Subcommands: update, finish, end, info
//

#import <Foundation/Foundation.h>
#import "ActivityOffload.h"
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

#if __has_include("Minis-Swift.h")
#import "Minis-Swift.h"
#elif __has_include("MinisApp-Swift.h")
#import "MinisApp-Swift.h"
#endif

static NSString *const TOOL_NAME = @"apple-activity";

static NSString *const HELP_TEXT =
    @"apple-activity - Control iOS Dynamic Island & Lock Screen Live Activities\n"
     "\n"
     "USAGE:\n"
     "  apple-activity <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  update      Update the status text and icon shown in the Dynamic Island\n"
     "  finish      Mark the current activity as completed with a resting message\n"
     "  end         Immediately dismiss and end the Live Activity\n"
     "  info        Check if Live Activities / Dynamic Island is supported and enabled\n"
     "\n"
     "UPDATE OPTIONS:\n"
     "  --status <text>     Status text shown in Dynamic Island (e.g. \"Searching web...\")\n"
     "  --icon <symbol>     SF Symbol icon name (e.g. \"globe\", \"terminal\", \"sparkles\")\n"
     "  --title <title>     Session title (default: \"Rovie Task\")\n"
     "\n"
     "FINISH OPTIONS:\n"
     "  --message <text>    Final summary message shown on the completed island card\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-activity update --status \"Searching docs...\" --icon \"magnifyingglass\"\n"
     "  apple-activity finish --message \"Found 3 matching accounts\"\n"
     "  apple-activity end\n";

static Class get_bridge_class(void) {
    return NSClassFromString(@"ActivityOffloadBridge");
}

static int cmd_update(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *status = noff_find_arg(argc, argv, "--status");
    if (!status) {
        NSArray<NSString *> *pos = noff_positional_args(argc, argv);
        if (pos.count > 0) status = pos[0];
    }

    if (!status || status.length == 0) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"update",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Status text required. Usage: apple-activity update --status <text> [--icon <symbol>]");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *icon = noff_find_arg(argc, argv, "--icon") ?: @"sparkles";
    NSString *title = noff_find_arg(argc, argv, "--title") ?: @"Rovie Task";

    Class bridge = get_bridge_class();
    BOOL ok = NO;
    if (bridge && [bridge respondsToSelector:@selector(updateStatusWithStatus:icon:title:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        ok = ((BOOL (*)(id, SEL, id, id, id))[bridge methodForSelector:@selector(updateStatusWithStatus:icon:title:)])(bridge, @selector(updateStatusWithStatus:icon:title:), status, icon, title);
#pragma clang diagnostic pop
    }

    NSDictionary *data = @{
        @"updated": @(ok),
        @"status": status,
        @"icon": icon,
        @"title": title
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"update", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_finish(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *msg = noff_find_arg(argc, argv, "--message");
    if (!msg) {
        NSArray<NSString *> *pos = noff_positional_args(argc, argv);
        if (pos.count > 0) msg = pos[0];
    }
    if (!msg) msg = @"Task completed";

    Class bridge = get_bridge_class();
    BOOL ok = NO;
    if (bridge && [bridge respondsToSelector:@selector(finishActivityWithMessage:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        ok = ((BOOL (*)(id, SEL, id))[bridge methodForSelector:@selector(finishActivityWithMessage:)])(bridge, @selector(finishActivityWithMessage:), msg);
#pragma clang diagnostic pop
    }

    NSDictionary *data = @{
        @"finished": @(ok),
        @"message": msg
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"finish", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_end(int stdout_fd, BOOL compact, BOOL quiet) {
    Class bridge = get_bridge_class();
    BOOL ok = NO;
    if (bridge && [bridge respondsToSelector:@selector(endActivity)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        ok = ((BOOL (*)(id, SEL))[bridge methodForSelector:@selector(endActivity)])(bridge, @selector(endActivity));
#pragma clang diagnostic pop
    }

    NSDictionary *data = @{ @"dismissed": @(ok) };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"end", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_info(int stdout_fd, BOOL compact, BOOL quiet) {
    Class bridge = get_bridge_class();
    BOOL available = NO;
    if (bridge && [bridge respondsToSelector:@selector(isAvailable)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        available = ((BOOL (*)(id, SEL))[bridge methodForSelector:@selector(isAvailable)])(bridge, @selector(isAvailable));
#pragma clang diagnostic pop
    }

    NSDictionary *data = @{
        @"supported": @YES,
        @"activity_kit_available": @(available),
        @"platform": @"iOS Dynamic Island / Live Activity"
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"info", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int activity_handler(int argc, char **argv,
                            int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        subcmd = @"info";
    }

    if ([subcmd isEqualToString:@"update"]) {
        return cmd_update(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"finish"]) {
        return cmd_finish(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"end"]) {
        return cmd_end(stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"info"]) {
        return cmd_info(stdout_fd, compact, quiet);
    }

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                         NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:@"Unknown command '%@'. Valid commands: update, finish, end, info.", subcmd]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void activity_offload_register(void) {
    int err = native_offload_add_handler("apple-activity", activity_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-activity");
        NSLog(@"NativeOffloads: apple-activity handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-activity handler (err=%d)", err);
    }
}

