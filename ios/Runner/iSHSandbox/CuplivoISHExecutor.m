//
//  CuplivoISHExecutor.m
//  Runner
//
//  Adapted from OpenMinis/MinisApp ISHShellExecutor.m (GPL-3.0, see
//  ios/sandbox/NOTICE), reduced to one-shot capture execution: no line
//  callbacks, no stdin feeding, result delivered as a single dictionary.
//

#import "CuplivoISHExecutor.h"
#import "CuplivoISHKernel.h"

#include "ish/kernel/init.h"
#include "ish/kernel/calls.h"
#include "ish/kernel/task.h"
#include "ish/kernel/signal.h"
#include "ish/kernel/fs.h"
#include "ish/fs/devices.h"
#include "ish/fs/real.h"
#include "ish/fs/path.h"
#include "ish/fs/stat.h"

#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>

/// Native per-stream capture cap; Dart applies its own 128K-char cap.
static const NSUInteger kMaxStreamBytes = 512 * 1024;
/// Grace period for readers to drain pipes after process exit.
static const NSTimeInterval kDrainGraceSeconds = 1.0;
/// Grace period for the exit notification to arrive after a timeout kill.
static const NSTimeInterval kKillGraceSeconds = 2.0;

#pragma mark - Execution context

@interface CuplivoISHExecutionContext : NSObject {
    int _stdoutPipe[2];
    int _stderrPipe[2];
}
@property (nonatomic) int guestPid;
@property (nonatomic, readonly) NSMutableData *stdoutData;
@property (nonatomic, readonly) NSMutableData *stderrData;
@property (nonatomic, readonly) dispatch_semaphore_t waitSemaphore;
@property (atomic) int exitCode;
@property (atomic) BOOL exited;
@property (atomic) BOOL stdoutReaderDone;
@property (atomic) BOOL stderrReaderDone;

- (int *)stdoutPipe;
- (int *)stderrPipe;
@end

@implementation CuplivoISHExecutionContext

- (int *)stdoutPipe {
    return _stdoutPipe;
}

- (int *)stderrPipe {
    return _stderrPipe;
}

- (instancetype)init {
    if (self = [super init]) {
        _stdoutData = [NSMutableData data];
        _stderrData = [NSMutableData data];
        _waitSemaphore = dispatch_semaphore_create(0);
        _stdoutPipe[0] = _stdoutPipe[1] = -1;
        _stderrPipe[0] = _stderrPipe[1] = -1;
        _exitCode = -1;
    }
    return self;
}

- (void)closePipeEnds {
    if (_stdoutPipe[0] >= 0) close(_stdoutPipe[0]);
    if (_stdoutPipe[1] >= 0) close(_stdoutPipe[1]);
    if (_stderrPipe[0] >= 0) close(_stderrPipe[0]);
    if (_stderrPipe[1] >= 0) close(_stderrPipe[1]);
    _stdoutPipe[0] = _stdoutPipe[1] = -1;
    _stderrPipe[0] = _stderrPipe[1] = -1;
}

- (void)dealloc {
    [self closePipeEnds];
}

@end

#pragma mark - Executor

@implementation CuplivoISHExecutor

static NSMutableDictionary<NSNumber *, CuplivoISHExecutionContext *> *_activeExecutions;
static dispatch_queue_t _execQueue;
static dispatch_queue_t _readerQueue;

+ (void)initialize {
    if (self == [CuplivoISHExecutor class]) {
        _activeExecutions = [NSMutableDictionary dictionary];
        _execQueue = dispatch_queue_create("com.cuplivo.ish.exec", DISPATCH_QUEUE_SERIAL);
        _readerQueue = dispatch_queue_create("com.cuplivo.ish.reader", DISPATCH_QUEUE_CONCURRENT);
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(processDidExit:)
                                                     name:CuplivoISHProcessExitedNotification
                                                   object:nil];
    }
}

#pragma mark - Public API

+ (void)executeCommand:(NSString *)command
                   cwd:(NSString *)cwd
               timeout:(NSTimeInterval)timeout
            completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    dispatch_async(_execQueue, ^{
        NSDictionary *result = [self runCommand:command cwd:cwd timeout:timeout];
        completion(result);
    });
}

#pragma mark - Execution core

+ (NSDictionary *)runCommand:(NSString *)command cwd:(nullable NSString *)cwd timeout:(NSTimeInterval)timeout {
    if (![CuplivoISHKernel shared].isBooted) {
        return [self errorResult:@"kernel not booted"];
    }

    CuplivoISHExecutionContext *ctx = [[CuplivoISHExecutionContext alloc] init];

    if (pipe([ctx stdoutPipe]) < 0 || pipe([ctx stderrPipe]) < 0) {
        NSLog(@"CuplivoISHExecutor: pipe() failed: %s", strerror(errno));
        return [self errorResult:[NSString stringWithFormat:@"pipe failed: %s", strerror(errno)]];
    }

    struct task *saved_current = current;

    int err = become_new_init_child();
    if (err < 0) {
        current = saved_current;
        NSLog(@"CuplivoISHExecutor: become_new_init_child failed: %d", err);
        return [self errorResult:[NSString stringWithFormat:@"become_new_init_child failed: %d", err]];
    }

    struct task *task = current;

    // stdin: /dev/null.
    struct fd *stdin_fd = adhoc_fd_create(&realfs_fdops);
    if (stdin_fd) {
        int real_fd = open("/dev/null", O_RDONLY);
        if (real_fd < 0) {
            current = saved_current;
            return [self errorResult:[NSString stringWithFormat:@"open /dev/null failed: %s", strerror(errno)]];
        }
        stdin_fd->real_fd = real_fd;
        task->files->files[0] = stdin_fd;
    }

    // stdout/stderr: pipes.
    struct fd *stdout_fd = adhoc_fd_create(&realfs_fdops);
    if (stdout_fd) {
        int real_fd = dup([ctx stdoutPipe][1]);
        if (real_fd < 0) {
            current = saved_current;
            return [self errorResult:@"dup(stdout) failed"];
        }
        stdout_fd->real_fd = real_fd;
        task->files->files[1] = stdout_fd;
    }
    struct fd *stderr_fd = adhoc_fd_create(&realfs_fdops);
    if (stderr_fd) {
        int real_fd = dup([ctx stderrPipe][1]);
        if (real_fd < 0) {
            current = saved_current;
            return [self errorResult:@"dup(stderr) failed"];
        }
        stderr_fd->real_fd = real_fd;
        task->files->files[2] = stderr_fd;
    }
    close([ctx stdoutPipe][1]);
    close([ctx stderrPipe][1]);
    [ctx stdoutPipe][1] = -1;
    [ctx stderrPipe][1] = -1;

    // Guest cwd (defaults to / set by inherit; apply requested cwd).
    if (cwd.length > 0) {
        struct statbuf st;
        int statErr = generic_statat(AT_PWD, cwd.UTF8String, &st, true);
        if (statErr < 0 || !(st.mode & S_IFDIR)) {
            current = saved_current;
            NSLog(@"CuplivoISHExecutor: cwd %@ not a directory (err=%d)", cwd, statErr);
            return [self errorResult:[NSString stringWithFormat:@"cwd not found: %@", cwd]];
        }
        struct fd *dir = generic_open(cwd.UTF8String, O_RDONLY_, 0);
        if (IS_ERR(dir)) {
            current = saved_current;
            return [self errorResult:[NSString stringWithFormat:@"cwd open failed: %ld", PTR_ERR(dir)]];
        }
        fs_chdir(task->fs, dir);
    }

    // argv: /bin/sh -c "<command>\n". busybox ash heredocs need the
    // trailing newline after the terminator (OpenMinis T-heredoc fix).
    NSString *normalized = [command hasSuffix:@"\n"] ? command : [command stringByAppendingString:@"\n"];
    NSArray<NSString *> *argvArray = @[@"/bin/sh", @"-c", normalized];
    char argv_buf[16384];
    size_t pos = 0;
    int exec_argc = 0;
    for (NSString *arg in argvArray) {
        const char *str = arg.UTF8String;
        size_t len = strlen(str) + 1;
        if (pos + len >= sizeof(argv_buf) - 1) {
            current = saved_current;
            return [self errorResult:@"argv too long"];
        }
        memcpy(argv_buf + pos, str, len);
        pos += len;
        exec_argc++;
    }
    argv_buf[pos] = '\0';

    // envp: NUL-separated, double-NUL terminated.
    char envp_buf[8192];
    size_t envp_pos = 0;
#define ENVP_APPEND(s) do { \
    const char *_s = (s); \
    size_t _len = strlen(_s) + 1; \
    if (envp_pos + _len < sizeof(envp_buf) - 256) { \
        memcpy(envp_buf + envp_pos, _s, _len); \
        envp_pos += _len; \
    } \
} while (0)

    ENVP_APPEND("TERM=xterm-256color");
    ENVP_APPEND("HOME=/root");
    ENVP_APPEND("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    ENVP_APPEND("LANG=C.UTF-8");
    ENVP_APPEND("CHARSET=UTF-8");
    ENVP_APPEND("NO_COLOR=1");
    ENVP_APPEND("PYTHONMALLOC=malloc");
    ENVP_APPEND("PYTHONDONTWRITEBYTECODE=1");
    // V8 cannot JIT under emulation; node honours NODE_OPTIONS.
    ENVP_APPEND("NODE_OPTIONS=--jitless --max-old-space-size=512");
    // Go tuning (ported from OpenMinis): cap the scheduler to one core-pair
    // so it does not spin extra threads under the interpreter, and disable
    // async preemption which is expensive under emulation.
    ENVP_APPEND("GOMAXPROCS=2");
    ENVP_APPEND("GODEBUG=asyncpreemptoff=1");
    // OpenMinis also injects ENV=/etc/profile and node LD_PRELOAD=/lib/zero_free.so;
    // both are intentionally omitted here pending rootfs confirmation (#361).

    // Device timezone for musl (POSIX TZ with fixed name; +/- abbreviations
    // confuse musl's parser — OpenMinis approach).
    {
        NSTimeZone *tz = [NSTimeZone systemTimeZone];
        NSInteger secs = tz.secondsFromGMT;
        NSInteger hrs = secs / 3600;
        NSInteger mins = labs(secs % 3600) / 60;
        NSString *posixTZ;
        if (mins != 0) {
            posixTZ = [NSString stringWithFormat:@"LCL%+ld:%02ld", (long)-hrs, (long)mins];
        } else {
            posixTZ = [NSString stringWithFormat:@"LCL%+ld", (long)-hrs];
        }
        NSString *tzEnv = [NSString stringWithFormat:@"TZ=%@", posixTZ];
        ENVP_APPEND(tzEnv.UTF8String);
    }
    envp_buf[envp_pos] = '\0';
#undef ENVP_APPEND

    err = do_execve("/bin/sh", exec_argc, argv_buf, envp_buf);
    if (err < 0) {
        current = saved_current;
        NSLog(@"CuplivoISHExecutor: do_execve failed: %d", err);
        return [self errorResult:[NSString stringWithFormat:@"do_execve failed: %d", err]];
    }

    ctx.guestPid = task->pid;
    task_start(task);
    current = saved_current;

    @synchronized(_activeExecutions) {
        _activeExecutions[@(ctx.guestPid)] = ctx;
    }

    [self startReaderForPipe:[ctx stdoutPipe][0] context:ctx isStdErr:NO];
    [self startReaderForPipe:[ctx stderrPipe][0] context:ctx isStdErr:YES];

    // Wait for exit or timeout.
    dispatch_time_t waitTime = timeout > 0
        ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))
        : DISPATCH_TIME_FOREVER;
    long waitResult = dispatch_semaphore_wait(ctx.waitSemaphore, waitTime);

    BOOL timedOut = NO;
    if (waitResult != 0) {
        timedOut = YES;
        [self killProcessGroup:ctx.guestPid];
        // Give the exit notification a chance to land so the exit code and
        // any partial output are captured.
        (void)dispatch_semaphore_wait(ctx.waitSemaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kKillGraceSeconds * NSEC_PER_SEC)));
    }

    // Let readers drain remaining pipe data before decoding.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kDrainGraceSeconds];
    while ((!ctx.stdoutReaderDone || !ctx.stderrReaderDone) &&
           [deadline timeIntervalSinceNow] > 0) {
        [NSThread sleepForTimeInterval:0.05];
    }

    @synchronized(_activeExecutions) {
        [_activeExecutions removeObjectForKey:@(ctx.guestPid)];
    }
    [ctx closePipeEnds];

    return @{
        @"exitCode": @(timedOut ? -1 : ctx.exitCode),
        @"stdout": [self decodeStream:ctx.stdoutData],
        @"stderr": [self decodeStream:ctx.stderrData],
        @"timedOut": @(timedOut),
    };
}

+ (NSDictionary *)errorResult:(NSString *)reason {
    NSLog(@"CuplivoISHExecutor: %@", reason);
    return @{
        @"exitCode": @(-1),
        @"stdout": @"",
        @"stderr": reason,
        @"timedOut": @NO,
        @"error": reason,
    };
}

+ (NSString *)decodeStream:(NSData *)data {
    if (data.length == 0) return @"";
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    return text ?: @"";
}

#pragma mark - Process exit handling

+ (void)processDidExit:(NSNotification *)notification {
    int pid = [notification.userInfo[@"pid"] intValue];
    int exitCode = [notification.userInfo[@"code"] intValue];

    CuplivoISHExecutionContext *ctx;
    @synchronized(_activeExecutions) {
        ctx = _activeExecutions[@(pid)];
    }
    if (!ctx) return;

    ctx.exitCode = exitCode;
    ctx.exited = YES;
    // Give pipe readers a moment to drain before waking the waiter.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        dispatch_semaphore_signal(ctx.waitSemaphore);
    });
}

#pragma mark - Pipe reading

+ (void)startReaderForPipe:(int)fd context:(CuplivoISHExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    dispatch_async(_readerQueue, ^{
        [self readPipe:fd context:ctx isStdErr:isStdErr];
    });
}

+ (void)readPipe:(int)fd context:(CuplivoISHExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    char buffer[4096];
    NSMutableData *out = isStdErr ? ctx.stderrData : ctx.stdoutData;
    struct pollfd pfd = {.fd = fd, .events = POLLIN};

    for (;;) {
        int pr = poll(&pfd, 1, 500);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pr == 0) {
            // EOF once the guest closed its end; after exit + grace the
            // caller stops using the buffer anyway.
            if (ctx.exited) break;
            continue;
        }
        if ((pfd.revents & (POLLHUP | POLLERR)) && !(pfd.revents & POLLIN)) {
            break;
        }
        ssize_t bytesRead = read(fd, buffer, sizeof(buffer));
        if (bytesRead > 0) {
            @synchronized(out) {
                if (out.length < kMaxStreamBytes) {
                    [out appendBytes:buffer length:(NSUInteger)bytesRead];
                    if (out.length > kMaxStreamBytes) {
                        [out setLength:kMaxStreamBytes];
                    }
                }
            }
        } else if (bytesRead == 0) {
            break; // EOF
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
            break;
        }
    }
    if (isStdErr) {
        ctx.stderrReaderDone = YES;
    } else {
        ctx.stdoutReaderDone = YES;
    }
}

#pragma mark - Kill

static BOOL CuplivoTaskIsDescendantOf(struct task *t, pid_t_ rootPid) {
    int hops = 0;
    while (t != NULL && hops < MAX_PID) {
        if (t->pid == rootPid) return YES;
        t = t->parent;
        hops++;
    }
    return NO;
}

/// SIGTERM the process group (pgid match or ancestry), then SIGKILL
/// survivors after a short delay. Ported from OpenMinis including the
/// pid-recycle safety rails.
+ (void)killProcessGroup:(int)pid {
    if (pid <= 1) {
        NSLog(@"CuplivoISHExecutor: refusing killProcessGroup for pid=%d", pid);
        return;
    }
    struct siginfo_ info = SIGINFO_NIL;

    lock(&pids_lock);
    struct task *rootTask = pid_get_task((dword_t)pid);
    pid_t_ pgid = 0;
    if (rootTask) {
        pgid = rootTask->group->pgid;
        for (int i = 2; i < MAX_PID; i++) {
            struct task *t = pid_get_task(i);
            if (!t) continue;
            BOOL byPgid = (pgid != 0 && t->group->pgid == pgid);
            BOOL byAncestry = CuplivoTaskIsDescendantOf(t, (pid_t_)pid);
            if (byPgid || byAncestry) {
                send_signal(t, SIGTERM_, info);
            }
        }
    }
    unlock(&pids_lock);

    if (rootTask == NULL) {
        return;
    }

    int capturedPid = pid;
    struct task *capturedRoot = rootTask;
    pid_t_ capturedPgid = pgid;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(0, 0), ^{
        lock(&pids_lock);
        struct task *still = pid_get_task((dword_t)capturedPid);
        if (still != capturedRoot) {
            unlock(&pids_lock);
            return;
        }
        for (int i = 2; i < MAX_PID; i++) {
            struct task *t = pid_get_task(i);
            if (!t) continue;
            BOOL byPgid = (capturedPgid != 0 && t->group->pgid == capturedPgid);
            BOOL byAncestry = CuplivoTaskIsDescendantOf(t, (pid_t_)capturedPid);
            if (byPgid || byAncestry) {
                send_signal(t, SIGKILL_, info);
            }
        }
        unlock(&pids_lock);
    });
}

@end
