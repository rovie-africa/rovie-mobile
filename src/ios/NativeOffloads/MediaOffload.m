//
//  MediaOffload.m
//  MinisApp
//
//  Native offload handler for `apple-media`.
//  Subcommands: now-playing, play, pause, toggle, next, prev, volume, search, play-search
//

#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

static NSString *const TOOL_NAME = @"apple-media";

static NSString *const HELP_TEXT =
    @"apple-media - Control iOS music playback and search the media library or Apple Music catalog\n"
     "\n"
     "USAGE:\n"
     "  apple-media [command] [options]\n"
     "\n"
     "COMMANDS:\n"
     "  now-playing  Get currently playing track info (default when no command given)\n"
     "  play         Resume playback\n"
     "  pause        Pause playback\n"
     "  toggle       Toggle play/pause\n"
     "  next         Skip to next track\n"
     "  prev         Skip to previous track\n"
     "  volume       Get or set system volume\n"
     "  search       Search local library and Apple Music streaming catalog\n"
     "  play-search  Search and immediately play (local library or Apple Music catalog)\n"
     "  play-id      Play an Apple Music catalog track or album by store_id\n"
     "  open         Open Apple Music app to a track or search query\n"
     "\n"
     "COMMON OPTIONS:\n"
     "  --help, -h           Show this help message\n"
     "  --compact            Minimize JSON output\n"
     "  -q, --quiet          Output only data field\n"
     "\n"
     "VOLUME OPTIONS:\n"
     "  --set <0.0-1.0>      Set volume level\n"
     "\n"
     "SEARCH OPTIONS:\n"
     "  --query <text>       Search query (required)\n"
     "  --type <type>        song, album, artist, playlist (default: song)\n"
     "  --limit <N>          Maximum results (default: 25)\n"
     "  --catalog            Search Apple Music streaming catalog directly\n"
     "  --country <code>     Storefront country code for catalog search (default: NG)\n"
     "\n"
     "PLAY-SEARCH OPTIONS:\n"
     "  --query <text>       Search query (required)\n"
     "  --type <type>        song, album, artist (default: song)\n"
     "  --catalog            Stream directly from Apple Music catalog\n"
     "  --country <code>     Storefront country code (default: NG)\n"
     "\n"
     "PLAY-ID OPTIONS:\n"
     "  --id <store_id>      Apple Music catalog track or album ID (required)\n"
     "\n"
     "OPEN OPTIONS:\n"
     "  --query <text>       Search query or track name to open in Apple Music\n"
     "  --id <store_id>      Apple Music store_id to open in Apple Music\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-media                    (same as: apple-media now-playing)\n"
     "  apple-media play\n"
     "  apple-media toggle\n"
     "  apple-media volume --set 0.5\n"
     "  apple-media search --query \"Burna Boy\" --catalog\n"
     "  apple-media play-search --query \"Last Last Burna Boy\"\n"
     "  apple-media play-id --id 1623886714\n";

// Serial queue to prevent concurrent authorization dialogs
static dispatch_queue_t authQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("com.openminis.media.auth", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// Request media library authorization synchronously
static BOOL requestMediaAccess(NSString **outError) {
    __block MPMediaLibraryAuthorizationStatus status;

    dispatch_sync(authQueue(), ^{
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        [MPMediaLibrary requestAuthorization:^(MPMediaLibraryAuthorizationStatus s) {
            status = s;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    });

    if (status != MPMediaLibraryAuthorizationStatusAuthorized) {
        if (outError) {
            *outError = @"Media library access not granted. "
                         "To grant access, open Settings > Privacy & Security > Media & Apple Music "
                         "and enable Minis.";
        }
        return NO;
    }
    return YES;
}

// Build a dict from an MPMediaItem
static NSDictionary *media_item_to_dict(MPMediaItem *item) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"title"] = item.title ?: [NSNull null];
    d[@"artist"] = item.artist ?: [NSNull null];
    d[@"album"] = item.albumTitle ?: [NSNull null];
    d[@"duration_seconds"] = @(item.playbackDuration);
    d[@"track_number"] = @(item.albumTrackNumber);
    d[@"genre"] = item.genre ?: [NSNull null];
    d[@"play_count"] = @(item.playCount);
    d[@"source"] = @"library";
    if (item.playbackStoreID.length > 0 && ![item.playbackStoreID isEqualToString:@"0"]) {
        d[@"store_id"] = item.playbackStoreID;
    }
    return d;
}

// Search the Apple Music / iTunes catalog via HTTPS (works on Free Personal Team without MusicKit entitlement)
static NSArray<NSDictionary *> *search_apple_music_catalog(NSString *query,
                                                           NSString *type,
                                                           NSString *country,
                                                           NSInteger limit,
                                                           NSString **outError) {
    NSString *entity = @"song";
    if ([type isEqualToString:@"album"]) {
        entity = @"album";
    } else if ([type isEqualToString:@"artist"]) {
        entity = @"musicArtist";
    }

    NSInteger clampedLimit = MIN(MAX(limit, 1), 50);
    NSString *storefront = (country.length > 0 ? country : @"NG").uppercaseString;

    NSURLComponents *comps = [NSURLComponents componentsWithString:@"https://itunes.apple.com/search"];
    comps.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"term" value:query],
        [NSURLQueryItem queryItemWithName:@"media" value:@"music"],
        [NSURLQueryItem queryItemWithName:@"entity" value:entity],
        [NSURLQueryItem queryItemWithName:@"country" value:storefront],
        [NSURLQueryItem queryItemWithName:@"limit" value:[NSString stringWithFormat:@"%ld", (long)clampedLimit]],
    ];

    NSURL *url = comps.URL;
    if (!url) {
        if (outError) *outError = @"Failed to construct Apple Music catalog search URL.";
        return nil;
    }

    __block NSData *respData = nil;
    __block NSError *reqErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 10.0;
    cfg.timeoutIntervalForResource = 12.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        respData = data;
        reqErr = error;
        dispatch_semaphore_signal(sem);
    }] resume];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC));
    [session finishTasksAndInvalidate];

    if (reqErr || !respData) {
        if (outError) {
            *outError = reqErr.localizedDescription ?: @"Apple Music catalog request timed out.";
        }
        return nil;
    }

    NSError *jsonErr = nil;
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:respData options:0 error:&jsonErr];
    if (jsonErr || ![payload isKindOfClass:[NSDictionary class]]) {
        if (outError) *outError = @"Invalid response from Apple Music catalog.";
        return nil;
    }

    NSArray *rawResults = payload[@"results"];
    if (![rawResults isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<NSDictionary *> *mapped = [NSMutableArray arrayWithCapacity:rawResults.count];
    for (NSDictionary *r in rawResults) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *trackId = r[@"trackId"] ?: r[@"collectionId"] ?: r[@"artistId"];
        NSString *storeId = trackId ? [trackId stringValue] : nil;
        NSString *title = r[@"trackName"] ?: r[@"collectionName"] ?: r[@"artistName"];
        NSString *artist = r[@"artistName"];
        NSString *album = r[@"collectionName"];
        NSNumber *timeMillis = r[@"trackTimeMillis"];
        NSString *viewUrl = r[@"trackViewUrl"] ?: r[@"collectionViewUrl"] ?: r[@"artistLinkUrl"];
        NSString *previewUrl = r[@"previewUrl"];
        NSString *genre = r[@"primaryGenreName"];

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"source"] = @"apple_music_catalog";
        entry[@"store_id"] = storeId ?: [NSNull null];
        entry[@"title"] = title ?: [NSNull null];
        entry[@"artist"] = artist ?: [NSNull null];
        entry[@"album"] = album ?: [NSNull null];
        entry[@"genre"] = genre ?: [NSNull null];
        if (timeMillis) {
            entry[@"duration_seconds"] = @(llround([timeMillis doubleValue] / 1000.0));
        } else {
            entry[@"duration_seconds"] = [NSNull null];
        }
        entry[@"apple_music_url"] = viewUrl ?: [NSNull null];
        entry[@"preview_url"] = previewUrl ?: [NSNull null];
        [mapped addObject:entry];
    }
    return mapped;
}

// Open a URL in Apple Music on the main thread
static BOOL open_apple_music_url(NSString *urlString) {
    if (!urlString.length) return NO;
    // Convert https://music.apple.com/... to music://music.apple.com/... so iOS opens Apple Music directly
    NSString *deepLink = urlString;
    if ([deepLink hasPrefix:@"https://music.apple.com/"]) {
        deepLink = [deepLink stringByReplacingOccurrencesOfString:@"https://music.apple.com/"
                                                       withString:@"music://music.apple.com/"];
    } else if ([deepLink hasPrefix:@"https://itunes.apple.com/"]) {
        deepLink = [deepLink stringByReplacingOccurrencesOfString:@"https://itunes.apple.com/"
                                                       withString:@"music://music.apple.com/"];
    }
    NSURL *url = [NSURL URLWithString:deepLink];
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
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC));
    return opened;
}

// Queue store IDs on MPMusicPlayerController and start playback
static BOOL queue_and_play_store_ids(NSArray<NSString *> *storeIDs, NSString **outError) {
    if (storeIDs.count == 0) {
        if (outError) *outError = @"No store IDs provided";
        return NO;
    }

    MPMusicPlayerController *player = [MPMusicPlayerController systemMusicPlayer];
    [player setQueueWithStoreIDs:storeIDs];

    __block NSError *prepError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [player prepareToPlayWithCompletionHandler:^(NSError * _Nullable error) {
        prepError = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC));

    [player play];
    usleep(350000);

    if (prepError && player.playbackState != MPMusicPlaybackStatePlaying) {
        if (outError) *outError = prepError.localizedDescription;
        return NO;
    }
    return YES;
}

// Build a now-playing info dict from the current player state.
//
// [T-media-nowplaying-watchdog] Runs on the CALLING (offload) thread, not the
// main queue. Reading `nowPlayingItem` deserializes an OPACK payload whose
// MPMediaLibrary rebuild needs the account DSID, and that lookup does its own
// dispatch_sync into iTunesCloud. Hopping to the main queue first meant a slow
// DSID lookup held the main thread past the 10s scene-update watchdog and the
// app was SIGKILLed (0x8BADF00D, incident 7FAE5E8E: app CPU ~0%, main thread
// parked in __DISPATCH_WAIT_FOR_QUEUE__ under -[MPMusicPlayerController
// nowPlayingItem]). MPMusicPlayerController is not a UIKit view and does not
// require the main thread for these reads, so the hop bought nothing and cost
// the app's liveness. Blocking here only stalls this one shell command.
static NSDictionary *now_playing_dict(void) {
    NSDictionary *result = nil;
    {
        MPMusicPlayerController *player = [MPMusicPlayerController systemMusicPlayer];
        MPMediaItem *item = player.nowPlayingItem;

        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        if (item) {
            d[@"title"] = item.title ?: [NSNull null];
            d[@"artist"] = item.artist ?: [NSNull null];
            d[@"album"] = item.albumTitle ?: [NSNull null];
            d[@"duration_seconds"] = @(item.playbackDuration);
            d[@"playback_time"] = @(player.currentPlaybackTime);
            d[@"artwork_available"] = @(item.artwork != nil);
        } else {
            d[@"title"] = [NSNull null];
            d[@"artist"] = [NSNull null];
            d[@"album"] = [NSNull null];
            d[@"duration_seconds"] = [NSNull null];
            d[@"playback_time"] = [NSNull null];
            d[@"artwork_available"] = @NO;
        }

        NSString *state;
        switch (player.playbackState) {
            case MPMusicPlaybackStatePlaying:          state = @"playing"; break;
            case MPMusicPlaybackStatePaused:           state = @"paused"; break;
            case MPMusicPlaybackStateStopped:          state = @"stopped"; break;
            case MPMusicPlaybackStateInterrupted:      state = @"interrupted"; break;
            case MPMusicPlaybackStateSeekingForward:   state = @"seeking_forward"; break;
            case MPMusicPlaybackStateSeekingBackward:  state = @"seeking_backward"; break;
            default:                                   state = @"unknown"; break;
        }
        d[@"playback_state"] = state;

        result = [d copy];
    }
    return result;
}

static int cmd_now_playing(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSDictionary *data = now_playing_dict();
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"now-playing", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_play(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    [[MPMusicPlayerController systemMusicPlayer] play];
    NSDictionary *data = @{@"status": @"playing"};
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"play", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_pause(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    [[MPMusicPlayerController systemMusicPlayer] pause];
    NSDictionary *data = @{@"status": @"paused"};
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"pause", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_toggle(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *newState = nil;
    {
        MPMusicPlayerController *player = [MPMusicPlayerController systemMusicPlayer];
        if (player.playbackState == MPMusicPlaybackStatePlaying) {
            [player pause];
            newState = @"paused";
        } else {
            [player play];
            newState = @"playing";
        }
    }
    NSDictionary *data = @{@"status": newState};
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"toggle", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_next(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    [[MPMusicPlayerController systemMusicPlayer] skipToNextItem];
    // Brief wait for track to change
    usleep(300000);

    NSDictionary *np = nil;
    {
        MPMediaItem *item = [MPMusicPlayerController systemMusicPlayer].nowPlayingItem;
        if (item) {
            np = @{
                @"title": item.title ?: [NSNull null],
                @"artist": item.artist ?: [NSNull null],
                @"album": item.albumTitle ?: [NSNull null],
            };
        }
    }

    NSDictionary *data = @{
        @"status": @"next",
        @"now_playing": np ?: [NSNull null],
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"next", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_prev(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    [[MPMusicPlayerController systemMusicPlayer] skipToPreviousItem];
    // Brief wait for track to change
    usleep(300000);

    NSDictionary *np = nil;
    {
        MPMediaItem *item = [MPMusicPlayerController systemMusicPlayer].nowPlayingItem;
        if (item) {
            np = @{
                @"title": item.title ?: [NSNull null],
                @"artist": item.artist ?: [NSNull null],
                @"album": item.albumTitle ?: [NSNull null],
            };
        }
    }

    NSDictionary *data = @{
        @"status": @"previous",
        @"now_playing": np ?: [NSNull null],
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"prev", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_volume(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *setStr = noff_find_arg(argc, argv, "--set");

    if (setStr) {
        float newVolume = [setStr floatValue];
        if (newVolume < 0.0f) newVolume = 0.0f;
        if (newVolume > 1.0f) newVolume = 1.0f;

        // [T-media-nowplaying-watchdog] This is the ONE site in this tool that
        // legitimately needs the main thread: MPVolumeView is a UIView and
        // instantiating/walking it off-main is undefined. It is bounded anyway —
        // building a detached view and poking its slider is pure UIKit with no
        // IPC, so it cannot block the way nowPlayingItem's DSID lookup did, but
        // the timeout keeps a wedged main queue from taking the process down.
        BOOL volTimedOut = NO;
        noff_dispatch_main_sync_timeout(3.0, &volTimedOut, ^id{
            MPVolumeView *volumeView = [[MPVolumeView alloc] initWithFrame:CGRectZero];
            UISlider *volumeSlider = nil;
            for (UIView *view in volumeView.subviews) {
                if ([view isKindOfClass:[UISlider class]]) {
                    volumeSlider = (UISlider *)view;
                    break;
                }
            }
            if (volumeSlider) {
                volumeSlider.value = newVolume;
                [volumeSlider sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
            return nil;
        });
        if (volTimedOut) {
            NSDictionary *err = noff_json_error(TOOL_NAME, @"volume",
                                                 NOFF_ERR_INTERNAL_ERROR,
                                                 @"Timed out waiting for the main thread to apply the volume change.");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }
        // Brief wait for volume change to take effect
        usleep(100000);
    }

    float currentVolume = [[AVAudioSession sharedInstance] outputVolume];

    NSDictionary *data = @{@"volume": @(currentVolume)};
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"volume", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_search(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *query = noff_find_arg(argc, argv, "--query");
    if (!query) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"search",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --query");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *type = noff_find_arg(argc, argv, "--type") ?: @"song";
    NSString *limitStr = noff_find_arg(argc, argv, "--limit");
    NSInteger limit = limitStr ? [limitStr integerValue] : 25;
    BOOL forceCatalog = noff_has_flag(argc, argv, "--catalog");
    NSString *country = noff_find_arg(argc, argv, "--country") ?: @"NG";

    NSMutableArray *results = [NSMutableArray array];
    NSInteger totalCount = 0;
    NSString *sourceUsed = @"library";

    if (!forceCatalog) {
        NSString *authErr = nil;
        if (requestMediaAccess(&authErr)) {
            MPMediaQuery *mediaQuery = nil;
            MPMediaPropertyPredicate *predicate = nil;

            if ([type isEqualToString:@"song"]) {
                mediaQuery = [MPMediaQuery songsQuery];
                predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                             forProperty:MPMediaItemPropertyTitle
                                                          comparisonType:MPMediaPredicateComparisonContains];
            } else if ([type isEqualToString:@"album"]) {
                mediaQuery = [MPMediaQuery albumsQuery];
                predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                             forProperty:MPMediaItemPropertyAlbumTitle
                                                          comparisonType:MPMediaPredicateComparisonContains];
            } else if ([type isEqualToString:@"artist"]) {
                mediaQuery = [MPMediaQuery artistsQuery];
                predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                             forProperty:MPMediaItemPropertyArtist
                                                          comparisonType:MPMediaPredicateComparisonContains];
            } else if ([type isEqualToString:@"playlist"]) {
                mediaQuery = [MPMediaQuery playlistsQuery];
                predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                             forProperty:MPMediaPlaylistPropertyName
                                                          comparisonType:MPMediaPredicateComparisonContains];
            } else {
                noff_emit_help(stderr_fd, HELP_TEXT);
                NSDictionary *err = noff_json_error(TOOL_NAME, @"search",
                                                     NOFF_ERR_INVALID_ARGS,
                                                     @"--type must be song, album, artist, or playlist");
                noff_emit_json(stdout_fd, err, compact, quiet);
                return NOFF_EXIT_INVALID_ARGS;
            }

            [mediaQuery addFilterPredicate:predicate];
            NSArray<MPMediaItem *> *items = mediaQuery.items ?: @[];
            totalCount = (NSInteger)items.count;
            if (totalCount > limit) {
                items = [items subarrayWithRange:NSMakeRange(0, limit)];
            }
            for (MPMediaItem *item in items) {
                [results addObject:media_item_to_dict(item)];
            }
        }
    }

    // Automatically fall back to Apple Music streaming catalog when local library has no matches (or --catalog is set)
    if (results.count == 0 && ![type isEqualToString:@"playlist"]) {
        NSString *catErr = nil;
        NSArray<NSDictionary *> *catalogItems = search_apple_music_catalog(query, type, country, limit, &catErr);
        if (catalogItems) {
            [results addObjectsFromArray:catalogItems];
            totalCount = (NSInteger)catalogItems.count;
            sourceUsed = @"apple_music_catalog";
        } else if (forceCatalog && catErr) {
            NSDictionary *err = noff_json_error(TOOL_NAME, @"search",
                                                 NOFF_ERR_INTERNAL_ERROR, catErr);
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }
    }

    NSMutableDictionary *data = [@{
        @"results": results,
        @"query": query,
        @"type": type,
        @"source": sourceUsed,
        @"count": @(results.count),
    } mutableCopy];
    if (totalCount > limit) {
        data[@"_warning"] = [NSString stringWithFormat:
            @"Results truncated by --limit. Returned %ld of %ld total records. "
             "Use a larger --limit to retrieve more data.",
            (long)limit, (long)totalCount];
        data[@"total_available"] = @(totalCount);
    }
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"search", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_play_search(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *query = noff_find_arg(argc, argv, "--query");
    if (!query) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"play-search",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --query");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *type = noff_find_arg(argc, argv, "--type") ?: @"song";
    BOOL forceCatalog = noff_has_flag(argc, argv, "--catalog");
    NSString *country = noff_find_arg(argc, argv, "--country") ?: @"NG";

    if (![type isEqualToString:@"song"] && ![type isEqualToString:@"album"] && ![type isEqualToString:@"artist"]) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"play-search",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"--type must be song, album, or artist");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *authErr = nil;
    BOOL hasMediaAuth = requestMediaAccess(&authErr);

    if (!forceCatalog && hasMediaAuth) {
        MPMediaQuery *mediaQuery = nil;
        MPMediaPropertyPredicate *predicate = nil;

        if ([type isEqualToString:@"song"]) {
            mediaQuery = [MPMediaQuery songsQuery];
            predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                         forProperty:MPMediaItemPropertyTitle
                                                      comparisonType:MPMediaPredicateComparisonContains];
        } else if ([type isEqualToString:@"album"]) {
            mediaQuery = [MPMediaQuery albumsQuery];
            predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                         forProperty:MPMediaItemPropertyAlbumTitle
                                                      comparisonType:MPMediaPredicateComparisonContains];
        } else if ([type isEqualToString:@"artist"]) {
            mediaQuery = [MPMediaQuery artistsQuery];
            predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                         forProperty:MPMediaItemPropertyArtist
                                                      comparisonType:MPMediaPredicateComparisonContains];
        }

        [mediaQuery addFilterPredicate:predicate];
        NSArray<MPMediaItem *> *items = mediaQuery.items;
        if (items && items.count > 0) {
            MPMusicPlayerController *player = [MPMusicPlayerController systemMusicPlayer];
            [player setQueueWithQuery:mediaQuery];
            [player play];
            usleep(300000);

            MPMediaItem *item = player.nowPlayingItem ?: items.firstObject;
            NSDictionary *np = item ? @{
                @"title": item.title ?: [NSNull null],
                @"artist": item.artist ?: [NSNull null],
                @"album": item.albumTitle ?: [NSNull null],
                @"source": @"library",
            } : (id)[NSNull null];

            NSDictionary *data = @{
                @"status": @"playing",
                @"source": @"library",
                @"now_playing": np,
            };
            noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"play-search", data), compact, quiet);
            return NOFF_EXIT_SUCCESS;
        }
    }

    // Search Apple Music streaming catalog and play via store_id queue
    NSString *catErr = nil;
    NSArray<NSDictionary *> *catalogItems = search_apple_music_catalog(query, type, country, 10, &catErr);
    if (!catalogItems || catalogItems.count == 0) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"play-search",
                                             NOFF_ERR_NO_DATA,
                                             catErr ?: [NSString stringWithFormat:@"No results in library or Apple Music catalog for '%@'", query]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSMutableArray<NSString *> *storeIDs = [NSMutableArray array];
    for (NSDictionary *entry in catalogItems) {
        id sid = entry[@"store_id"];
        if ([sid isKindOfClass:[NSString class]] && [(NSString *)sid length] > 0) {
            [storeIDs addObject:sid];
        }
    }

    NSDictionary *firstMatch = catalogItems.firstObject;
    NSString *playErr = nil;
    BOOL queuedPlaying = NO;
    if (hasMediaAuth && storeIDs.count > 0) {
        queuedPlaying = queue_and_play_store_ids(storeIDs, &playErr);
    }

    // If systemMusicPlayer didn't start streaming (e.g. Apple Music app wasn't warmed up or no active subscription),
    // deep-link straight into the track in Apple Music app so the user lands right on it.
    BOOL openedInMusicApp = NO;
    if (!queuedPlaying) {
        NSString *appleMusicUrl = [firstMatch[@"apple_music_url"] isKindOfClass:[NSString class]]
            ? firstMatch[@"apple_music_url"]
            : nil;
        if (appleMusicUrl) {
            openedInMusicApp = open_apple_music_url(appleMusicUrl);
        }
    }

    NSDictionary *np = @{
        @"store_id": firstMatch[@"store_id"] ?: [NSNull null],
        @"title": firstMatch[@"title"] ?: [NSNull null],
        @"artist": firstMatch[@"artist"] ?: [NSNull null],
        @"album": firstMatch[@"album"] ?: [NSNull null],
        @"apple_music_url": firstMatch[@"apple_music_url"] ?: [NSNull null],
        @"source": @"apple_music_catalog",
    };

    NSMutableDictionary *data = [@{
        @"status": queuedPlaying ? @"playing" : (openedInMusicApp ? @"opened_in_apple_music" : @"matched"),
        @"source": @"apple_music_catalog",
        @"now_playing": np,
    } mutableCopy];
    if (playErr && !queuedPlaying) {
        data[@"playback_note"] = playErr;
    }

    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"play-search", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_play_id(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *storeId = noff_find_arg(argc, argv, "--id");
    if (!storeId.length) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"play-id",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --id <store_id>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *authErr = nil;
    if (!requestMediaAccess(&authErr)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"play-id",
                                             NOFF_ERR_AUTHORIZATION_DENIED, authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_AUTH_DENIED;
    }

    NSString *playErr = nil;
    BOOL ok = queue_and_play_store_ids(@[storeId], &playErr);
    NSDictionary *np = now_playing_dict();

    NSMutableDictionary *data = [@{
        @"status": ok ? @"playing" : @"failed",
        @"store_id": storeId,
        @"now_playing": np ?: [NSNull null],
    } mutableCopy];
    if (playErr) {
        data[@"playback_note"] = playErr;
    }

    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"play-id", data), compact, quiet);
    return ok ? NOFF_EXIT_SUCCESS : NOFF_EXIT_ERROR;
}

static int cmd_open(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *storeId = noff_find_arg(argc, argv, "--id");
    NSString *query = noff_find_arg(argc, argv, "--query");
    NSString *country = (noff_find_arg(argc, argv, "--country") ?: @"ng").lowercaseString;

    NSString *targetUrl = @"music://";
    NSDictionary *matchedTrack = nil;

    if (storeId.length > 0) {
        targetUrl = [NSString stringWithFormat:@"music://music.apple.com/%@/song/%@", country, storeId];
    } else if (query.length > 0) {
        NSString *catErr = nil;
        NSArray<NSDictionary *> *items = search_apple_music_catalog(query, @"song", country, 1, &catErr);
        if (items.count > 0) {
            matchedTrack = items.firstObject;
            NSString *viewUrl = [matchedTrack[@"apple_music_url"] isKindOfClass:[NSString class]]
                ? matchedTrack[@"apple_music_url"]
                : nil;
            if (viewUrl.length > 0) {
                targetUrl = viewUrl;
            }
        }
    }

    BOOL opened = open_apple_music_url(targetUrl);
    NSDictionary *data = @{
        @"opened": @(opened),
        @"url": targetUrl,
        @"matched_track": matchedTrack ?: [NSNull null],
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"open", data), compact, quiet);
    return opened ? NOFF_EXIT_SUCCESS : NOFF_EXIT_ERROR;
}

static int media_handler(int argc, char **argv,
                          int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        // [T-offload-defaults-batch-ios] Bare `apple-media` (including
        // flags-only invocations) defaults to `now-playing` — a read-only
        // status query; never silently mutates playback.
        subcmd = @"now-playing";
    }

    if ([subcmd isEqualToString:@"now-playing"])  return cmd_now_playing(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"play"])          return cmd_play(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"pause"])         return cmd_pause(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"toggle"])        return cmd_toggle(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"next"])          return cmd_next(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"prev"])          return cmd_prev(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"volume"])        return cmd_volume(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"search"])        return cmd_search(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"play-search"])   return cmd_play_search(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"play-id"])       return cmd_play_id(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"open"])          return cmd_open(argc, argv, stdout_fd, stderr_fd, compact, quiet);

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                         NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:@"Unknown command '%@'. Valid commands: now-playing, play, pause, toggle, next, prev, volume, search, play-search, play-id, open. Use --help for details.", subcmd]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void media_offload_register(void) {
    int err = native_offload_add_handler("apple-media", media_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-media");
        NSLog(@"NativeOffloads: apple-media handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-media handler (err=%d)", err);
    }
}
