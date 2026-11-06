

#import "DPOLogCenter.h"

#import <execinfo.h>
#import <fcntl.h>
#import <pthread.h>
#import <signal.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

static NSString *const DPOLogPreferredPath = @"/var/mobile/Library/Preferences/com.dpo.pluginnest.log";
static NSString *const DPOLogFallbackName = @"com.dpo.pluginnest.log";
static NSString *const DPOCrashFileName = @"com.dpo.pluginnest.crash";
static const NSUInteger DPOLogMaxLines = 4000;

static NSUncaughtExceptionHandler *DPOPreviousExceptionHandler = NULL;

static int DPOCrashFD = -1;

// 下面这几个函数只使用 write()/strlen() 这类 async-signal-safe 的调用。
// 崩溃处理器里绝不能碰 printf/strsignal/backtrace_symbols/fsync/Objective-C：
// 它们可能 malloc 或加锁，而崩溃时锁很可能已经被持有。
static void DPOSignalWrite(int fd, const char *text) {
    if (fd < 0 || text == NULL) return;
    size_t length = strlen(text);
    const char *cursor = text;
    while (length > 0) {
        ssize_t written = write(fd, cursor, length);
        if (written <= 0) return;
        cursor += written;
        length -= (size_t)written;
    }
}

static void DPOSignalWriteDecimal(int fd, unsigned long long value) {
    char buffer[24];
    int index = 0;
    if (value == 0) buffer[index++] = '0';
    while (value > 0 && index < (int)sizeof(buffer)) {
        buffer[index++] = (char)('0' + (int)(value % 10));
        value /= 10;
    }
    for (int left = 0, right = index - 1; left < right; left++, right--) {
        char swap = buffer[left];
        buffer[left] = buffer[right];
        buffer[right] = swap;
    }
    ssize_t ignored = write(fd, buffer, (size_t)index);
    (void)ignored;
}

static void DPOSignalWriteHex(int fd, unsigned long long value) {
    static const char digits[] = "0123456789abcdef";
    char buffer[18];
    int index = 0;
    buffer[index++] = '0';
    buffer[index++] = 'x';
    if (value == 0) {
        buffer[index++] = '0';
    } else {
        char reversed[16];
        int count = 0;
        while (value > 0 && count < (int)sizeof(reversed)) {
            reversed[count++] = digits[(int)(value & 0xF)];
            value >>= 4;
        }
        while (count > 0) buffer[index++] = reversed[--count];
    }
    ssize_t ignored = write(fd, buffer, (size_t)index);
    (void)ignored;
}

static const char *DPOSignalName(int sig) {
    switch (sig) {
        case SIGABRT: return "SIGABRT";
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGFPE:  return "SIGFPE";
        case SIGTRAP: return "SIGTRAP";
        default:      return "SIGNAL";
    }
}

static void DPOSignalHandler(int sig, siginfo_t *info, void *context) {
    (void)context;

    int fd = DPOCrashFD;
    if (fd >= 0) {
        DPOSignalWrite(fd, "\n[CRASH] signal=");
        DPOSignalWriteDecimal(fd, (unsigned long long)sig);
        DPOSignalWrite(fd, " (");
        DPOSignalWrite(fd, DPOSignalName(sig));
        DPOSignalWrite(fd, ") addr=");
        DPOSignalWriteHex(fd, (unsigned long long)(uintptr_t)(info != NULL ? info->si_addr : NULL));
        DPOSignalWrite(fd, " thread=");
        DPOSignalWrite(fd, pthread_main_np() ? "main" : "background");
        DPOSignalWrite(fd, "\n");

        void *frames[64];
        int count = backtrace(frames, 64);
        for (int index = 0; index < count; index++) {
            DPOSignalWrite(fd, "#");
            DPOSignalWriteDecimal(fd, (unsigned long long)index);
            DPOSignalWrite(fd, "  ");
            DPOSignalWriteHex(fd, (unsigned long long)(uintptr_t)frames[index]);
            DPOSignalWrite(fd, "\n");
        }
        // 不做 fsync：它不是 async-signal-safe，进程退出时内核会把页缓存刷下去。
    }

    signal(sig, SIG_DFL);
    raise(sig);
}

static void DPOInstallSignalHandlers(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = DPOSignalHandler;
    action.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&action.sa_mask);

    const int signals[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP };
    for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]); index++) {
        sigaction(signals[index], &action, NULL);
    }
}

static void DPOUncaughtExceptionHandler(NSException *exception) {
    @try {
        DPOLogEvent(@"CRASH", @"%@: %@", exception.name, exception.reason);
        NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"];
        if (stack.length > 0) DPOLogEvent(@"CRASH", @"%@", stack);
        [[DPOLogCenter shared] flushSync];
    } @catch (__unused NSException *ignored) {
    }
    if (DPOPreviousExceptionHandler != NULL) {
        DPOPreviousExceptionHandler(exception);
    }
}

@implementation DPOLogCenter {
    NSMutableArray<NSString *> *_lines;
    NSLock *_lock;
    NSDateFormatter *_formatter;      
    NSString *_filePath;
    int _fd;
    BOOL _started;
    BOOL _dirty;
    NSUInteger _generation;   // 每次 _lines 变化自增，用来判断「写盘期间有没有新日志」
}

+ (instancetype)shared {
    static DPOLogCenter *center = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        center = [[DPOLogCenter alloc] init];
    });
    return center;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lines = [NSMutableArray array];
        _lock = [[NSLock alloc] init];
        _filePath = DPOLogPreferredPath;
        _fd = -1;
    }
    return self;
}

- (void)start {
    if (_started) return;
    _started = YES;

    
    
    _filePath = [self dpo_resolveWritablePath];

    
    [self dpo_loadPreviousSession];
    [self dpo_loadPreviousCrash];

    
    [self dpo_compactIfNeeded];
    [self dpo_openLogFile];

    [self dpo_openCrashFile];
    DPOInstallSignalHandlers();

    DPOPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&DPOUncaughtExceptionHandler);

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(dpo_flushNotification:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(dpo_flushNotification:)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
}

- (void)dpo_flushNotification:(NSNotification *)notification {
    [self flush];
}

#pragma mark - 路径

- (NSString *)dpo_tmpLogPath {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:DPOLogFallbackName];
}

- (NSString *)dpo_resolveWritablePath {
    NSString *directory = [DPOLogPreferredPath stringByDeletingLastPathComponent];
    if (access(directory.fileSystemRepresentation, W_OK) == 0) return DPOLogPreferredPath;

    NSString *fallback = [self dpo_tmpLogPath];
    NSString *fallbackDirectory = [fallback stringByDeletingLastPathComponent];
    if (access(fallbackDirectory.fileSystemRepresentation, W_OK) == 0) return fallback;
    return DPOLogPreferredPath;
}

- (void)dpo_loadPreviousSession {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *best = nil;
    NSDate *bestDate = nil;

    for (NSString *candidate in @[ DPOLogPreferredPath, [self dpo_tmpLogPath] ]) {
        NSDictionary *attributes = [manager attributesOfItemAtPath:candidate error:NULL];
        if (attributes == nil) continue;
        NSDate *modified = attributes[NSFileModificationDate];
        BOOL newer = (bestDate == nil) ||
                     (modified != nil && [modified compare:bestDate] == NSOrderedDescending);
        if (best == nil || newer) {
            best = candidate;
            bestDate = modified;
        }
    }
    if (best == nil) return;

    NSString *previous = [NSString stringWithContentsOfFile:best
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    if (previous.length == 0) return;

    NSArray<NSString *> *lines = [previous componentsSeparatedByString:@"\n"];
    if (lines.count == 0) return;

    [_lock lock];
    if (lines.count > DPOLogMaxLines - 400) {
        lines = [lines subarrayWithRange:NSMakeRange(lines.count - (DPOLogMaxLines - 400),
                                                     DPOLogMaxLines - 400)];
    }
    [_lines addObjectsFromArray:lines];
    [_lines addObject:@"──────── 以上为上次运行 ────────"];
    _dirty = YES;
    _generation += 1;
    [_lock unlock];
}

#pragma mark - 崩溃现场

- (NSString *)dpo_crashFilePath {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:DPOCrashFileName];
}

- (void)dpo_loadPreviousCrash {
    NSString *path = [self dpo_crashFilePath];
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    if (content.length > 0) {
        [_lock lock];
        [_lines addObject:@"──────── 上次崩溃现场 ────────"];
        for (NSString *line in [content componentsSeparatedByString:@"\n"]) {
            if (line.length > 0) [_lines addObject:line];
        }
        _dirty = YES;
        _generation += 1;
        [_lock unlock];
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

- (void)dpo_openCrashFile {
    NSString *path = [self dpo_crashFilePath];
    if (path.length == 0) return;
    DPOCrashFD = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
}

#pragma mark - 落盘

- (void)dpo_openLogFile {
    if (_fd >= 0) close(_fd);
    _fd = -1;
    if (_filePath.length == 0) return;
    _fd = open(_filePath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
}

- (void)dpo_appendLineLocked:(NSString *)line {
    if (_fd < 0) return;
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) return;
    ssize_t ignored = write(_fd, data.bytes, data.length);
    (void)ignored;
}

- (void)dpo_compactIfNeeded {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:_filePath error:NULL];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    if (size < 512 * 1024) return;

    [_lock lock];
    NSArray *snapshot = [_lines copy];
    [_lock unlock];
    if (snapshot.count == 0) return;

    NSString *text = [snapshot componentsJoinedByString:@"\n"];
    [text writeToFile:_filePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

#pragma mark - 记录

- (void)log:(NSString *)category format:(NSString *)format, ... {
    if (format.length == 0) return;

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (message == nil) return;

    
    
    [_lock lock];
    if (_formatter == nil) {
        _formatter = [[NSDateFormatter alloc] init];
        _formatter.dateFormat = @"HH:mm:ss.SSS";
    }
    NSString *stamp = [_formatter stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@",
                      stamp, category.length > 0 ? category : @"INFO", message];

    [_lines addObject:line];
    if (_lines.count > DPOLogMaxLines) {
        [_lines removeObjectsInRange:NSMakeRange(0, _lines.count - DPOLogMaxLines)];
    }
    _dirty = YES;
    _generation += 1;
    [self dpo_appendLineLocked:line];
    [_lock unlock];

    
    if (DPOLogEnabled()) NSLog(@"[PluginNest] %@", line);
}

- (NSArray<NSString *> *)lines {
    [_lock lock];
    NSArray *copy = [_lines copy];
    [_lock unlock];
    return copy;
}

- (NSString *)text {
    [_lock lock];
    NSArray *copy = [_lines copy];
    [_lock unlock];
    if (copy.count == 0) return @"";
    return [copy componentsJoinedByString:@"\n"];
}

- (NSString *)filePath {
    [_lock lock];
    NSString *path = [_filePath copy];
    [_lock unlock];
    return path;
}

- (void)flush {
    [_lock lock];
    if (!_dirty) {
        [_lock unlock];
        return;
    }
    NSUInteger generation = _generation;
    NSArray *copy = [_lines copy];
    NSString *path = [_filePath copy];
    [_lock unlock];

    if (copy.count == 0 || path.length == 0) return;

    NSString *text = [copy componentsJoinedByString:@"\n"];
    BOOL written = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (!written) {
        NSString *fallback = [self dpo_tmpLogPath];
        if ([path isEqualToString:fallback]) return;   // 保持 dirty，等下次重试
        written = [text writeToFile:fallback atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        if (!written) return;                          // 两条路都失败：保留 dirty

        [_lock lock];
        _filePath = fallback;
        [_lock unlock];
    }

    [_lock lock];
    // 写盘期间又有新日志：保持 dirty，下一次 flush 会把它们一起写下去。
    // （旧实现先清 dirty 再写盘，这段时间的日志会静默丢掉。）
    if (_generation == generation) _dirty = NO;
    [self dpo_openLogFile];
    [_lock unlock];
}

- (void)flushSync {
    [self flush];
}

- (void)clear {
    [_lock lock];
    [_lines removeAllObjects];
    _dirty = YES;
    _generation += 1;
    NSString *path = [_filePath copy];
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
    [_lock unlock];

    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:[self dpo_crashFilePath] error:NULL];

    [_lock lock];
    [self dpo_openLogFile];
    [_lock unlock];

    DPOLogEvent(@"LOG", @"日志已清空，当前版本 %@", DPOBuildVersion);
}

@end
