#include "CTerminalSession.h"
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
static volatile sig_atomic_t terminating;
static void notified(int signal) { if (signal != SIGCHLD) terminating = 1; }

// FD 3 is private to the daemon and this session holder. The spawned program
// inherits only the terminal on 0/1/2. An explicit zero acknowledges the spawn;
// EOF alone could be the holder's dynamic loader failing before main.
static void report(int error) {
    int32_t report = error;
    const char *bytes = (const char *)&report;
    size_t remaining = sizeof(report);
    while (remaining) {
        ssize_t sent = write(3, bytes, remaining);
        if (sent > 0) { bytes += sent; remaining -= (size_t)sent; }
        else if (sent < 0 && errno == EINTR) continue;
        else break;
    }
}

static void failed(int error) { report(error); _exit(127); }

static unsigned int identifier(const char *value) {
    char *end;
    errno = 0;
    unsigned long result = strtoul(value, &end, 10);
    if (!*value || *end || errno || result > UINT_MAX) failed(EINVAL);
    return (unsigned int)result;
}

void fila_terminal_session_if_requested(int argc, char *const argv[]) {
    if (argc < 2 || strcmp(argv[1], "--terminal-session")) return;
    // Internal argv: mode, uid (or '-' to keep identity), gid, cwd, program,
    // then the program's fixed argv as composed by TerminalPlan.
    if (argc < 7 || argv[5][0] != '/') failed(EINVAL);
    if (setsid() < 0 || ioctl(STDIN_FILENO, TIOCSCTTY, 0) < 0) failed(errno);
    if (strcmp(argv[2], "-")) {
        uid_t uid = identifier(argv[2]);
        gid_t gid = identifier(argv[3]);
        if (getuid() != 0 || uid == 0) failed(EPERM);
        if (fchown(STDIN_FILENO, uid, gid) < 0 || setgroups(1, &gid) < 0 || setgid(gid) < 0
            || setuid(uid) < 0) failed(errno);
        if (getuid() != uid || geteuid() != uid || getgid() != gid || getegid() != gid || setuid(0) == 0) failed(EPERM);
    }
    // Enter directories with the session's credentials, never the daemon's.
    if (chdir(argv[4]) < 0 && chdir("/") < 0) failed(errno);

    sigset_t watched, previous;
    sigemptyset(&watched);
    sigaddset(&watched, SIGCHLD);
    sigaddset(&watched, SIGHUP);
    sigaddset(&watched, SIGTERM);
    struct sigaction action = {0};
    action.sa_handler = notified;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGCHLD, &action, NULL) < 0 || sigaction(SIGHUP, &action, NULL) < 0
        || sigaction(SIGTERM, &action, NULL) < 0
        || sigprocmask(SIG_BLOCK, &watched, &previous) < 0) failed(errno);

    posix_spawn_file_actions_t files;
    posix_spawnattr_t attributes;
    int error = posix_spawn_file_actions_init(&files);
    if (error) failed(error);
    for (int fd = 0; fd < 3; fd++) {
        if ((error = posix_spawn_file_actions_addinherit_np(&files, fd))) failed(error);
    }
    if ((error = posix_spawnattr_init(&attributes))) failed(error);
    sigset_t defaults, empty;
    sigfillset(&defaults);
    sigemptyset(&empty);
    if ((error = posix_spawnattr_setsigdefault(&attributes, &defaults))
        || (error = posix_spawnattr_setsigmask(&attributes, &empty))
        || (error = posix_spawnattr_setpgroup(&attributes, 0))
        || (error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED))) failed(error);
    pid_t child = -1;
    error = posix_spawn(&child, argv[5], &files, &attributes, &argv[6], environ);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&files);
    if (error) failed(error);
    // The child must not read until its group owns the terminal. Suspension
    // closes that setup race; it does not replace the session-holder process.
    if (tcsetpgrp(STDIN_FILENO, child) < 0 || kill(child, SIGCONT) < 0) {
        error = errno;
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        failed(error);
    }
    report(0);
    close(3);

    // Keep the child waitable until the last group signal: its PID must not be
    // reused under a delayed killpg. The daemon owns this holder's separate
    // group, and gives it two seconds before forcing termination.
    while (!terminating) {
        siginfo_t information = {0};
        if (waitid(P_PID, child, &information, WEXITED | WNOHANG | WNOWAIT) < 0) {
            if (errno == EINTR) continue;
            _exit(127);
        }
        if (information.si_pid == child) break;
        sigsuspend(&previous);
    }
    killpg(child, SIGHUP);
    // One second leaves room for cleanup before the daemon's two-second cap.
    struct timespec remaining = { .tv_sec = 1, .tv_nsec = 0 };
    while (nanosleep(&remaining, &remaining) < 0 && errno == EINTR) {}
    killpg(child, SIGKILL);
    int status = 0;
    while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) _exit(127); }
    _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
}

#ifdef FILA_TERMINAL_SESSION_STANDALONE
int main(int argc, char **argv) {
    fila_terminal_session_if_requested(argc, argv);
    return 64;
}
#endif
