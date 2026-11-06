//
//  ShortcutsOffload.m
//  MinisApp
//
//  Native offload handler for `apple-shortcuts`.
//  Subcommands: run, open, list
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "ShortcutsOffload.h"
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

static NSString *const TOOL_NAME = @"apple-shortcuts";

static NSString *const HELP_TEXT =
    @"apple-shortcuts - Run and manage Apple Shortcuts on iOS\n"
     "\n"
     "USAGE:\n"
     "  apple-shortcuts <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  run         Run an Apple Shortcut by name\n"
     "  open        Open a shortcut in the Shortcuts app (or open Shortcuts app)\n"
     "  list        Show pre-configured Rovie shortcuts and usage instructions\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h          Show this help message\n"
     "  --compact           Minimize JSON output\n"
     "  -q, --quiet         Output only data field\n"
     "  --name <shortcut>   Name of the shortcut to run or open\n"
     "  --input <text>      Input text passed to the shortcut\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-shortcuts run \"Send WhatsApp\" --input \"Meeting in 10 mins\"\n"
     "  apple-shortcuts run \"Log Weight\" --input \"75.5\"\n"
     "  apple-shortcuts open \"Send WhatsApp\"\n"
     "  apple-shortcuts list\n";

static NSString *url_encode(NSString *str) {
    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: str;
}

static int cmd_run(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *name = noff_find_arg(argc, argv, "--name");
    if (!name) {
        NSArray<NSString *> *pos = noff_positional_args(argc, argv);
        if (pos.count > 0) name = pos[0];
    }

    if (!name || name.length == 0) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"run",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Shortcut name required. Usage: apple-shortcuts run <name> [--input <text>]");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *input = noff_find_arg(argc, argv, "--input");

    NSMutableString *urlStr = [NSMutableString stringWithFormat:@"shortcuts://run-shortcut?name=%@", url_encode(name)];
    if (input && input.length > 0) {
        [urlStr appendFormat:@"&input=text&text=%@", url_encode(input)];
    }

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"run",
                                             NOFF_ERR_INVALID_ARGS,
                                             [NSString stringWithFormat:@"Invalid shortcut URL: %@", urlStr]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    __block BOOL opened = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:url
                                         options:@{}
                               completionHandler:^(BOOL success) {
            opened = success;
            dispatch_semaphore_signal(sem);
        }];
    });

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    NSDictionary *data = @{
        @"shortcut": name,
        @"input": input ?: [NSNull null],
        @"url": urlStr,
        @"launched": @(opened)
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"run", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_open(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *name = noff_find_arg(argc, argv, "--name");
    if (!name) {
        NSArray<NSString *> *pos = noff_positional_args(argc, argv);
        if (pos.count > 0) name = pos[0];
    }

    NSString *urlStr = (name && name.length > 0)
        ? [NSString stringWithFormat:@"shortcuts://open-shortcut?name=%@", url_encode(name)]
        : @"shortcuts://";

    NSURL *url = [NSURL URLWithString:urlStr];

    __block BOOL opened = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:url
                                         options:@{}
                               completionHandler:^(BOOL success) {
            opened = success;
            dispatch_semaphore_signal(sem);
        }];
    });

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    NSDictionary *data = @{
        @"shortcut": name ?: @"(shortcuts library)",
        @"url": urlStr,
        @"opened": @(opened)
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"open", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_list(int stdout_fd, BOOL compact, BOOL quiet) {
    NSArray *builtInIntents = @[
        @{
            @"intent": @"AskRovie",
            @"phrases": @[@"Ask Rovie", @"Talk to Rovie", @"Ask Rovie a question"],
            @"description": @"Start a conversational chat or ask questions"
        },
        @{
            @"intent": @"QuickTask",
            @"phrases": @[@"Run a Rovie quick task", @"Use Rovie quick task"],
            @"description": @"Run a focused single-step action in the background"
        },
        @{
            @"intent": @"SendPrompt",
            @"phrases": @[@"Send a prompt to Rovie", @"Start a Rovie task"],
            @"description": @"Send an automated instruction to the agent"
        },
        @{
            @"intent": @"GetSessionStatus",
            @"phrases": @[@"Get Rovie session status", @"Check Rovie task"],
            @"description": @"Inspect running tasks from the Lock Screen or Siri"
        },
        @{
            @"intent": @"ListSessions",
            @"phrases": @[@"List Rovie sessions", @"Show Rovie chats"],
            @"description": @"List active or recent sessions"
        }
    ];

    NSDictionary *data = @{
        @"description": @"Apple Shortcuts allows the agent to run user-configured automations (WhatsApp, Spotify, Smart Home, etc.) via `apple-shortcuts run <name>`.",
        @"system_shortcuts": builtInIntents,
        @"execution_scheme": @"shortcuts://run-shortcut?name=<name>&input=text&text=<input>"
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"list", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int shortcuts_handler(int argc, char **argv,
                             int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        subcmd = @"list";
    }

    if ([subcmd isEqualToString:@"run"]) {
        return cmd_run(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"open"]) {
        return cmd_open(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"list"]) {
        return cmd_list(stdout_fd, compact, quiet);
    }

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                         NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:@"Unknown command '%@'. Valid commands: run, open, list.", subcmd]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void shortcuts_offload_register(void) {
    int err = native_offload_add_handler("apple-shortcuts", shortcuts_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-shortcuts");
        NSLog(@"NativeOffloads: apple-shortcuts handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-shortcuts handler (err=%d)", err);
    }
}
