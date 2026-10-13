// Помощник «Сейчас играет» для Mac Utils.
// С macOS 15.4 MediaRemote отдаёт данные только системным программам, поэтому Mac Utils
// загружает эту библиотеку в /usr/bin/perl (системный процесс) и общается с ней строками:
// stdout — JSON о треке раз в секунду, stdin — команды: toggle, play, pause, next, prev, seek <сек>.
#import <AppKit/AppKit.h>
#include <dlfcn.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetPID)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetPlaying)(dispatch_queue_t, void (^)(BOOL));
typedef Boolean (*MRSend)(int, NSDictionary *);
typedef void (*MRSetElapsed)(double);

static MRGetInfo getInfo;
static MRGetPID getPID;
static MRGetPlaying getPlaying;
static MRSend sendCommand;
static MRSetElapsed setElapsed;
static NSString *lastArtworkKey = nil;

// Видео в браузере играет служебный процесс (WebKit GPU) — показываем саму программу.
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t);

static void emit(NSDictionary *info, int pid, BOOL playing) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    out[@"title"] = title ?: @"";
    out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
    out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
    out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
    double elapsed = [info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
    double rate = [info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if (stamp && rate > 0) elapsed += [[NSDate date] timeIntervalSinceDate:stamp] * rate;
    out[@"elapsed"] = @(elapsed);
    out[@"playing"] = @(playing);
    pid_t owner = pid > 0 ? responsibility_get_pid_responsible_for_pid(pid) : 0;
    NSRunningApplication *app = owner > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:owner] : nil;
    if (!app && pid > 0) app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    out[@"app"] = app.localizedName ?: @"";
    out[@"bundle"] = app.bundleIdentifier ?: @"";
    // Обложку шлём только когда трек сменился.
    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%lu", title, out[@"artist"], (unsigned long)artwork.length];
    if (artwork.length > 0 && ![key isEqualToString:lastArtworkKey]) {
        out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
        lastArtworkKey = key;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    if (json) {
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }
}

static void poll(void) {
    dispatch_queue_t queue = dispatch_get_global_queue(0, 0);
    getInfo(queue, ^(NSDictionary *info) {
        getPID(queue, ^(int pid) {
            getPlaying(queue, ^(BOOL playing) {
                emit(info ?: @{}, pid, playing);
            });
        });
    });
}

static void handle(NSString *line) {
    NSArray *parts = [line componentsSeparatedByString:@" "];
    NSString *command = parts.firstObject;
    if ([command isEqualToString:@"play"]) sendCommand(0, nil);
    else if ([command isEqualToString:@"pause"]) sendCommand(1, nil);
    else if ([command isEqualToString:@"toggle"]) sendCommand(2, nil);
    else if ([command isEqualToString:@"next"]) sendCommand(4, nil);
    else if ([command isEqualToString:@"prev"]) sendCommand(5, nil);
    else if ([command isEqualToString:@"seek"] && parts.count > 1) setElapsed([parts[1] doubleValue]);
    else if ([command isEqualToString:@"quit"]) exit(0);
    poll();
}

void mu_now_playing(void) {
    void *handle_ = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!handle_) exit(2);
    getInfo = (MRGetInfo)dlsym(handle_, "MRMediaRemoteGetNowPlayingInfo");
    getPID = (MRGetPID)dlsym(handle_, "MRMediaRemoteGetNowPlayingApplicationPID");
    getPlaying = (MRGetPlaying)dlsym(handle_, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sendCommand = (MRSend)dlsym(handle_, "MRMediaRemoteSendCommand");
    setElapsed = (MRSetElapsed)dlsym(handle_, "MRMediaRemoteSetElapsedTime");
    if (!getInfo || !getPID || !getPlaying || !sendCommand || !setElapsed) exit(3);

    // Команды из stdin; конец ввода — Mac Utils закрылся, выходим.
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        char buffer[256];
        while (fgets(buffer, sizeof buffer, stdin)) {
            NSString *line = [[NSString stringWithUTF8String:buffer]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{ handle(line); });
        }
        exit(0);
    });
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{ poll(); });
    dispatch_resume(timer);
    CFRunLoopRun();
}
