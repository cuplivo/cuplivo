//
//  CuplivoISHCrashGuards.c
//  Runner
//
//  Adapted from the embedded-iSH crash containment in OpenMinis/MinisApp
//  (ISHKernel.m) and ish-arm64 main.c, which are GPL-3.0; see
//  ios/sandbox/NOTICE. A guest crash must take down at most the guest task
//  thread, never the whole Flutter app.
//

// The iOS 26+ SDK (ucontext.h:50) makes <ucontext.h> a hard #error unless
// _XOPEN_SOURCE is defined: the getcontext/setcontext/makecontext/swapcontext
// routines are deprecated and gated behind the feature macro. This file only
// uses the ucontext_t struct (uc_mcontext), but the header requires the gate
// regardless.
#define _XOPEN_SOURCE 700

#include "CuplivoISHCrashGuards.h"

#include "ish/debug.h"
#include "ish/cpu-offsets.h"

#include <execinfo.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <sys/select.h>
#include <ucontext.h>
#include <unistd.h>

// Thread-local recovery state defined in asbestos.c.
extern __thread volatile sig_atomic_t in_jit;
#ifdef GUEST_ARM64
extern __thread volatile uint64_t jit_saved_pc;
#else
extern __thread volatile uint32_t jit_saved_pc;
#endif
// Set on every iSH task thread (asbestos.c); never set on host threads.
extern __thread int ish_thread_marker;

#ifdef GUEST_ARM64
// Assembly trampoline: returns INT_JIT_CRASH via fiber_exit (entry.S).
extern void jit_crash_trampoline(void);
#endif

/// Park the calling thread forever with all signals blocked. Used instead of
/// _exit()/abort() which would kill the entire app process; pthread_exit()
/// itself can trap with SIGTRAP on iOS in certain thread states.
static void park_thread_forever(void) {
    sigset_t all;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, NULL);
    for (;;) {
        select(0, NULL, NULL, NULL, NULL);
    }
}

/// Handles SIGSEGV/SIGBUS/SIGILL/SIGTRAP. On iSH threads inside guest code,
/// redirect execution to jit_crash_trampoline so the emulator returns an
/// INT_JIT_CRASH interrupt instead of killing the process. On non-iSH
/// threads (Flutter/UI/networking) restore the default handler and re-raise
/// so normal crash reporting still applies.
static void cuplivo_jit_crash_handler(int sig, siginfo_t *info, void *ctx) {
#if defined(__aarch64__) && defined(GUEST_ARM64)
    if ((sig == SIGSEGV || sig == SIGBUS) && in_jit) {
        ucontext_t *uc = (ucontext_t *)ctx;

        // _cpu is in x1 — pointer to cpu_state within fiber_frame.
        uint64_t cpu_ptr = uc->uc_mcontext->__ss.__x[1];

        // Reconstruct guest segfault_addr from registers:
        // x7 = host pointer (data_minus_addr + guest_addr), x10 may hold
        // data_minus_addr from the TLB hit path.
        uint64_t x7 = uc->uc_mcontext->__ss.__x[7];
        uint64_t x10 = uc->uc_mcontext->__ss.__x[10];
        uint64_t guest_addr = (x7 - x10) & 0xffffffffffffULL;

        uint64_t esr = uc->uc_mcontext->__es.__esr;
        int was_write = (esr & 0x40) != 0;

        *(uint64_t *)(cpu_ptr + CPU_segfault_addr) = guest_addr;
        *(int *)(cpu_ptr + CPU_segfault_was_write) = was_write;
        *(uint64_t *)(cpu_ptr + CPU_pc) = (uint64_t)jit_saved_pc;

        // Restore SP to the value saved by fiber_enter, then redirect
        // execution to the crash trampoline.
        uint64_t exit_sp = *(uint64_t *)(cpu_ptr + LOCAL_jit_exit_sp);
        uc->uc_mcontext->__ss.__sp = exit_sp;
        uc->uc_mcontext->__ss.__pc = (uint64_t)jit_crash_trampoline;

        // Unblock the signal so it can fire again.
        sigset_t unblock;
        sigemptyset(&unblock);
        sigaddset(&unblock, sig);
        sigprocmask(SIG_UNBLOCK, &unblock, NULL);
        return;
    }
#endif

    if (!ish_thread_marker) {
        // Not an iSH thread — restore default handling and re-raise so the
        // system crash reporter sees the fault.
        struct sigaction sa_default = {0};
        sa_default.sa_handler = SIG_DFL;
        sigaction(sig, &sa_default, NULL);
        raise(sig);
        return;
    }

    // Non-JIT crash on an iSH guest thread: log diagnostics and park only
    // this thread; _exit() would kill the whole app.
    char buf[512];
    int len = snprintf(buf, sizeof(buf),
                       "\n=== iSH guest crash: signal %d ===\nfault addr: %p\n",
                       sig, info->si_addr);
    if (len > 0) write(STDERR_FILENO, buf, (size_t)len);
    void *bt[20];
    int n = backtrace(bt, 20);
    backtrace_symbols_fd(bt, n, STDERR_FILENO);
    park_thread_forever();
}

void CuplivoISHInstallCrashGuards(void) {
    static char altstack[SIGSTKSZ];
    stack_t ss = {.ss_sp = altstack, .ss_size = SIGSTKSZ};
    sigaltstack(&ss, NULL);

    struct sigaction sa = {0};
    sa.sa_sigaction = cuplivo_jit_crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    // SIGABRT intentionally NOT handled — it is used by the system (assert,
    // Swift runtime, malloc) and intercepting it would mask real failures.
}

/// Custom die() handler: iSH's die() normally abort()s; embedded in the app
/// it must only stop the offending thread.
static void cuplivo_die_handler(const char *msg) {
    char buf[4096];
    int len = snprintf(buf, sizeof(buf), "\n=== iSH fatal: %s ===\n", msg);
    if (len > 0) write(STDERR_FILENO, buf, (size_t)len);
    park_thread_forever();
}

void CuplivoISHInstallDieGuard(void) {
    die_handler = cuplivo_die_handler;
}
