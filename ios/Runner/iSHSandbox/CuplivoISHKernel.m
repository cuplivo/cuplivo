//
//  CuplivoISHKernel.m
//  Runner
//
//  Boot sequence adapted from OpenMinis/MinisApp ISHKernel.m (GPL-3.0, see
//  ios/sandbox/NOTICE), stripped of app-specific offloads and hooks.
//

#import "CuplivoISHKernel.h"
#import "CuplivoISHCrashGuards.h"

#include "ish/kernel/init.h"
#include "ish/kernel/task.h"
#include "ish/kernel/calls.h"
#include "ish/kernel/fs.h"
#include "ish/fs/fake.h"
#include "ish/fs/tty.h"
#include "ish/fs/dev.h"
#include "ish/fs/devices.h"
#include "ish/fs/path.h"
#include "ish/fs/fd.h"

#include <pthread.h>
#include <sys/syslimits.h>

NSNotificationName const CuplivoISHProcessExitedNotification = @"CuplivoISHProcessExited";

static NSString *const kDnsSubdir = @"CuplivoSandbox/dns";
static const char *kPublicDns[] = {"1.1.1.1", "8.8.8.8", "223.5.5.5"};

// Exit hook exposed by kernel/task.c.
extern void (*exit_hook)(struct task *task, int code);

#pragma mark - Console TTY driver

// Init's stdio goes to a console TTY whose output is discarded: sandbox
// commands run with pipe-based stdio (CuplivoISHExecutor), the console only
// exists so PID 1 has valid fds.
static int cuplivo_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void)tty;
    (void)buf;
    (void)blocking;
    return (int)len;
}

static int cuplivo_tty_init(struct tty *tty) {
    (void)tty;
    return 0;
}

static void cuplivo_tty_cleanup(struct tty *tty) {
    (void)tty;
}

static struct tty_driver_ops cuplivo_console_ops = {
    .init = cuplivo_tty_init,
    .write = cuplivo_tty_write,
    .cleanup = cuplivo_tty_cleanup,
};

DEFINE_TTY_DRIVER(cuplivo_console_driver, &cuplivo_console_ops, TTY_CONSOLE_MAJOR, 8);

#pragma mark - Process exit handler

static void cuplivo_handle_process_exit(struct task *task, int code) {
    // Only notify for init (parent == NULL) and direct children of init
    // (parent->parent == NULL) — mirrors OpenMinis and avoids pids_lock
    // contention with sys_wait4.
    if (task->parent != NULL && task->parent->parent != NULL)
        return;
    pid_t pid = task->pid;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:CuplivoISHProcessExitedNotification
                          object:nil
                        userInfo:@{@"pid": @(pid), @"code": @(code)}];
    });
}

#pragma mark - CuplivoISHKernel

@implementation CuplivoISHKernel {
    BOOL _isBooted;
    NSString *_rootPath;
    NSString *_dataPath;
    NSString *_dnsHostPath;
}

+ (instancetype)shared {
    static CuplivoISHKernel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CuplivoISHKernel alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isBooted = NO;
    }
    return self;
}

- (BOOL)isBooted {
    return _isBooted;
}

- (NSString *)bootRootPath {
    return _rootPath;
}

- (int)bootWithRootPath:(NSString *)rootPath {
    if (_isBooted) {
        NSLog(@"CuplivoISHKernel: already booted");
        return 0;
    }

    int err;

    // 0. Crash containment before any guest code runs.
    CuplivoISHInstallCrashGuards();
    CuplivoISHInstallDieGuard();

    // 1. Mount the root filesystem (fakefs: data/ + meta.db).
    _rootPath = rootPath;
    _dataPath = [rootPath stringByAppendingPathComponent:@"data"];
    err = mount_root(&fakefs, _dataPath.fileSystemRepresentation);
    if (err < 0) {
        NSLog(@"CuplivoISHKernel: mount_root failed: %d", err);
        _rootPath = nil;
        _dataPath = nil;
        return err;
    }
    NSLog(@"CuplivoISHKernel: root filesystem mounted at %@", _dataPath);

    // Register the canonical host path of the rootfs data dir so fakefs can
    // suppress self-containing bind mounts (see fake.c).
    char canonical_data_path[PATH_MAX];
    if (realpath(_dataPath.fileSystemRepresentation, canonical_data_path) != NULL) {
        fakefs_set_rootfs_data_path(canonical_data_path);
    } else {
        NSLog(@"CuplivoISHKernel: realpath(data) failed (errno=%d), bind-mount cycle guard disabled", errno);
    }

    // 2. Become init process (PID 1). Irreversible for this process.
    err = become_first_process();
    if (err < 0) {
        NSLog(@"CuplivoISHKernel: become_first_process failed: %d", err);
        return err;
    }
    current->thread = pthread_self();
    NSLog(@"CuplivoISHKernel: init process created (PID 1)");

    // 3. Device nodes.
    [self createDeviceNodes];

    // 4. Mount proc and devpts.
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    NSLog(@"CuplivoISHKernel: /proc and /dev/pts mounted");

    // 5. DNS: /etc/resolv.conf as a file-level bind mount onto a host file
    // so it can be refreshed without touching meta.db.
    [self mountDnsConfig];

    // 6. Exit hook for command completion tracking.
    exit_hook = cuplivo_handle_process_exit;

    // 7. Console TTY + stdio for init.
    tty_drivers[TTY_CONSOLE_MAJOR] = &cuplivo_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0) {
        NSLog(@"CuplivoISHKernel: create_stdio failed: %d (non-fatal)", err);
    }

    _isBooted = YES;
    NSLog(@"CuplivoISHKernel: kernel initialized");
    return 0;
}

- (void)createDeviceNodes {
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);

    generic_mknodat(AT_PWD, "/dev/tty1", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 1));
    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));

    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
    NSLog(@"CuplivoISHKernel: device nodes created");
}

- (void)mountDnsConfig {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *library = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dnsDir = [library stringByAppendingPathComponent:kDnsSubdir];
    _dnsHostPath = [dnsDir stringByAppendingPathComponent:@"resolv.conf"];

    if (![fm fileExistsAtPath:dnsDir]) {
        [fm createDirectoryAtPath:dnsDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if (![fm fileExistsAtPath:_dnsHostPath]) {
        [self seedDnsFile];
    }

    int err = fakefs_bind_mount("/etc/resolv.conf", _dnsHostPath.fileSystemRepresentation, false);
    if (err < 0) {
        NSLog(@"CuplivoISHKernel: DNS bind mount failed (%d) — writing through VFS", err);
        struct task *prev = current;
        current = pid_get_task(1);
        if (current) {
            NSString *seed = [NSString stringWithContentsOfFile:_dnsHostPath encoding:NSUTF8StringEncoding error:nil];
            if (seed) {
                struct fd *fd = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0666);
                if (!IS_ERR(fd)) {
                    fd->ops->write(fd, seed.UTF8String, [seed lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
                    fd_close(fd);
                }
            }
        }
        current = prev;
        return;
    }
    NSLog(@"CuplivoISHKernel: DNS bind mount OK: /etc/resolv.conf -> %@", _dnsHostPath);
}

- (void)seedDnsFile {
    NSMutableString *content = [NSMutableString string];
    for (size_t i = 0; i < sizeof(kPublicDns) / sizeof(kPublicDns[0]); i++) {
        [content appendFormat:@"nameserver %s\n", kPublicDns[i]];
    }
    [content writeToFile:_dnsHostPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"CuplivoISHKernel: seeded host resolv.conf at %@", _dnsHostPath);
}

- (int)bindMountPath:(NSString *)linuxPath toHostPath:(NSString *)hostPath {
    if (!_isBooted) {
        NSLog(@"CuplivoISHKernel: bindMount failed — kernel not booted");
        return -1;
    }
    int err = fakefs_bind_mount(linuxPath.fileSystemRepresentation,
                                hostPath.fileSystemRepresentation, false);
    if (err < 0) {
        NSLog(@"CuplivoISHKernel: bindMount %@ -> %@ failed: %d", linuxPath, hostPath, err);
    }
    return err;
}

- (int)bindUnmountPath:(NSString *)linuxPath {
    if (!_isBooted) {
        return -1;
    }
    return fakefs_bind_unmount(linuxPath.fileSystemRepresentation);
}

@end
