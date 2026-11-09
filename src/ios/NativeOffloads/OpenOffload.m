//
//  OpenOffload.m
//  MinisApp
//
//  Native offload handler for `apple-open`.
//  Opens URLs, URL schemes, and system settings via UIApplication.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

static NSString *const TOOL_NAME = @"apple-open";

static NSString *const HELP_TEXT =
    @"apple-open - Open Apple apps, URLs, deep actions, and system settings\n"
     "\n"
     "USAGE:\n"
     "  apple-open <url_or_app_name>\n"
     "  apple-open apps\n"
     "  apple-open compose-sms --to <phone> [--body <text>]\n"
     "  apple-open compose-mail --to <email> [--subject <subj>] [--body <text>]\n"
     "  apple-open compose-whatsapp [--to <phone>] [--text <text>]\n"
     "  apple-open call --to <phone_or_apple_id> [--facetime] [--audio]\n"
     "  apple-open settings[://page]\n"
     "\n"
     "NAMED APPS:\n"
     "  music, notes, podcasts, reminders, calendar, maps, mail, messages,\n"
     "  facetime, facetime-audio, weather, health, wallet, books, files,\n"
     "  freeform, shortcuts, voicememos, findmy, clock, photos, appstore,\n"
     "  whatsapp, spotify, youtube\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h       Show this help message\n"
     "  --compact        Minimize JSON output\n"
     "  -q, --quiet      Output only data field\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-open music\n"
     "  apple-open notes\n"
     "  apple-open podcasts\n"
     "  apple-open compose-sms --to \"+2348012345678\" --body \"On my way\"\n"
     "  apple-open compose-mail --to \"team@rovie.africa\" --subject \"Update\" --body \"Ready\"\n"
     "  apple-open compose-whatsapp --to \"2348012345678\" --text \"Hello from Rovie\"\n"
     "  apple-open call --to \"+2348012345678\" --facetime --audio\n"
     "  apple-open \"maps://?q=Lekki+Phase+1\"\n"
     "  apple-open settings://wifi\n";

static NSDictionary<NSString *, NSString *> *named_app_schemes(void) {
    return @{
        @"music":          @"music://",
        @"apple-music":    @"music://",
        @"notes":          @"mobilenotes://",
        @"apple-notes":    @"mobilenotes://",
        @"podcasts":       @"podcasts://",
        @"apple-podcasts": @"podcasts://",
        @"reminders":      @"x-apple-reminderkit://",
        @"calendar":       @"calshow://",
        @"maps":           @"maps://",
        @"apple-maps":     @"maps://",
        @"mail":           @"message://",
        @"messages":       @"sms:",
        @"imessage":       @"sms:",
        @"facetime":       @"facetime://",
        @"facetime-audio": @"facetime-audio://",
        @"weather":        @"weather://",
        @"health":         @"x-apple-health://",
        @"wallet":         @"shoebox://",
        @"books":          @"ibooks://",
        @"apple-books":    @"ibooks://",
        @"files":          @"shareddocuments://",
        @"freeform":       @"freeform://",
        @"shortcuts":      @"shortcuts://",
        @"voicememos":     @"voicememos://",
        @"voice-memos":    @"voicememos://",
        @"findmy":         @"findmy://",
        @"find-my":        @"findmy://",
        @"clock":          @"clock-alarm://",
        @"photos":         @"photos-redirect://",
        @"appstore":       @"itms-apps://",
        @"app-store":      @"itms-apps://",
        @"whatsapp":       @"whatsapp://",
        @"spotify":        @"spotify://",
        @"youtube":        @"youtube://",
    };
}

// Map shorthand settings and app names to URL strings
static NSString *resolve_settings_url(NSString *input) {
    NSString *lower = input.lowercaseString;
    if ([lower isEqualToString:@"settings"]) {
        return UIApplicationOpenSettingsURLString;
    }
    NSString *appScheme = named_app_schemes()[lower];
    if (appScheme) {
        return appScheme;
    }
    if ([lower hasPrefix:@"settings://"]) {
        NSString *page = [input substringFromIndex:@"settings://".length];
        NSDictionary *map = @{
            @"wifi":          @"App-Prefs:root=WIFI",
            @"bluetooth":     @"App-Prefs:root=Bluetooth",
            @"notifications": @"App-Prefs:root=NOTIFICATIONS_ID",
            @"general":       @"App-Prefs:root=General",
            @"display":       @"App-Prefs:root=DISPLAY",
            @"sounds":        @"App-Prefs:root=Sounds",
            @"battery":       @"App-Prefs:root=BATTERY_USAGE",
            @"privacy":       @"App-Prefs:root=Privacy",
            @"cellular":      @"App-Prefs:root=MOBILE_DATA_SETTINGS_ID",
            @"music":         @"App-Prefs:root=MUSIC",
        };
        NSString *url = map[page.lowercaseString];
        return url ?: [NSString stringWithFormat:@"App-Prefs:root=%@", page];
    }
    return input;
}

static BOOL open_url_sync(NSURL *url) {
    if (!url) return NO;
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
    return opened;
}

static NSString *percent_encode_query_value(NSString *val) {
    if (!val) return @"";
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"&+=?/#"];
    return [val stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static int open_handler(int argc, char **argv,
                         int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"open",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"No URL or app name specified. Use --help for usage.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    if ([subcmd isEqualToString:@"apps"]) {
        NSDictionary *schemes = named_app_schemes();
        NSArray *sortedNames = [schemes.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSDictionary *data = @{
            @"apps": sortedNames,
            @"schemes": schemes,
            @"actions": @[@"compose-sms", @"compose-mail", @"compose-whatsapp", @"call"],
        };
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"apps", data), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    if ([subcmd isEqualToString:@"compose-sms"]) {
        NSString *to = noff_find_arg(argc, argv, "--to") ?: @"";
        NSString *body = noff_find_arg(argc, argv, "--body");
        NSString *urlStr = nil;
        if (body.length > 0) {
            urlStr = [NSString stringWithFormat:@"sms:%@&body=%@",
                      percent_encode_query_value(to),
                      percent_encode_query_value(body)];
        } else {
            urlStr = [NSString stringWithFormat:@"sms:%@", percent_encode_query_value(to)];
        }
        NSURL *url = [NSURL URLWithString:urlStr];
        BOOL opened = open_url_sync(url);
        NSDictionary *data = @{
            @"action": @"compose-sms",
            @"to": to,
            @"resolved_url": urlStr,
            @"opened": @(opened),
        };
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"compose-sms", data), compact, quiet);
        return opened ? NOFF_EXIT_SUCCESS : NOFF_EXIT_ERROR;
    }

    if ([subcmd isEqualToString:@"compose-mail"]) {
        NSString *to = noff_find_arg(argc, argv, "--to") ?: @"";
        NSString *subject = noff_find_arg(argc, argv, "--subject");
        NSString *body = noff_find_arg(argc, argv, "--body");
        NSMutableArray *params = [NSMutableArray array];
        if (subject.length > 0) {
            [params addObject:[NSString stringWithFormat:@"subject=%@", percent_encode_query_value(subject)]];
        }
        if (body.length > 0) {
            [params addObject:[NSString stringWithFormat:@"body=%@", percent_encode_query_value(body)]];
        }
        NSString *queryPart = params.count > 0 ? [NSString stringWithFormat:@"?%@", [params componentsJoinedByString:@"&"]] : @"";
        NSString *urlStr = [NSString stringWithFormat:@"mailto:%@%@", percent_encode_query_value(to), queryPart];
        NSURL *url = [NSURL URLWithString:urlStr];
        BOOL opened = open_url_sync(url);
        NSDictionary *data = @{
            @"action": @"compose-mail",
            @"to": to,
            @"resolved_url": urlStr,
            @"opened": @(opened),
        };
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"compose-mail", data), compact, quiet);
        return opened ? NOFF_EXIT_SUCCESS : NOFF_EXIT_ERROR;
    }

    if ([subcmd isEqualToString:@"compose-whatsapp"]) {
        NSString *to = noff_find_arg(argc, argv, "--to");
        NSString *text = noff_find_arg(argc, argv, "--text") ?: noff_find_arg(argc, argv, "--body");
        NSMutableArray *params = [NSMutableArray array];
        if (to.length > 0) {
            NSString *cleanPhone = [[to componentsSeparatedByCharactersInSet:
                                     [[NSCharacterSet decimalDigitCharacterSet] invertedSet]]
                                    componentsJoinedByString:@""];
            if (cleanPhone.length > 0) {
                [params addObject:[NSString stringWithFormat:@"phone=%@", cleanPhone]];
            }
        }
        if (text.length > 0) {
            [params addObject:[NSString stringWithFormat:@"text=%@", percent_encode_query_value(text)]];
        }
        NSString *urlStr = params.count > 0
            ? [NSString stringWithFormat:@"whatsapp://send?%@", [params componentsJoinedByString:@"&"]]
            : @"whatsapp://";
        NSURL *url = [NSURL URLWithString:urlStr];
        BOOL opened = open_url_sync(url);
        NSDictionary *data = @{
            @"action": @"compose-whatsapp",
            @"to": to ?: [NSNull null],
            @"resolved_url": urlStr,
            @"opened": @(opened),
        };
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"compose-whatsapp", data), compact, quiet);
        return opened ? NOFF_EXIT_SUCCESS : NOFF_EXIT_ERROR;
    }

    if ([subcmd isEqualToString:@"call"]) {
        NSString *to = noff_find_arg(argc, argv, "--to");
        if (!to.length) {
            NSDictionary *err = noff_json_error(TOOL_NAME, @"call",
                                                 NOFF_ERR_INVALID_ARGS,
                                                 @"Required: --to <phone_or_apple_id>");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        BOOL useFaceTime = noff_has_flag(argc, argv, "--facetime");
        BOOL audioOnly = noff_has_flag(argc, argv, "--audio");
        NSString *scheme = @"tel:";
        if (useFaceTime) {
            scheme = audioOnly ? @"facetime-audio://" : @"facetime://";
        }
        NSString *urlStr = [NSString stringWithFormat:@"%@%@", scheme, percent_encode_query_value(to)];
        NSURL *url = [NSURL URLWithString:urlStr];
        BOOL opened = open_url_sync(url);
        NSDictionary *data = @{
            @"action": @"call",
            @"to": to,
            @"resolved_url": urlStr,
            @"opened": @(opened),
        };
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"call", data), compact, quiet);
        return opened ? NOFF_EXIT_SUCCESS : NOFF_EXIT_ERROR;
    }

    NSString *resolvedURL = resolve_settings_url(subcmd);
    NSURL *url = [NSURL URLWithString:resolvedURL];
    if (!url) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"open",
                                             NOFF_ERR_INVALID_ARGS,
                                             [NSString stringWithFormat:@"Invalid URL: %@", subcmd]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    BOOL opened = open_url_sync(url);

    NSDictionary *data = @{
        @"url": subcmd,
        @"resolved_url": resolvedURL,
        @"opened": @(opened),
    };
    NSDictionary *result = noff_json_envelope(TOOL_NAME, @"open", data);
    noff_emit_json(stdout_fd, result, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

void open_offload_register(void) {
    int err = native_offload_add_handler("apple-open", open_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-open");
        NSLog(@"NativeOffloads: apple-open handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-open handler (err=%d)", err);
    }
}
