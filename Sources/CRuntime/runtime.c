#define _GNU_SOURCE
#include "CRuntime.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

const char *scr_error_message(int32_t error_number) { return strerror(error_number); }
const char *scr_stage_name(int32_t stage) {
    switch (stage) {
    case 1: return "create launch pipe";
    case 2: return "fork launcher";
    case 3: return "create namespaces";
    case 4: return "make mount propagation private";
    case 5: return "fork namespace init";
    case 6: return "mount proc";
    case 7: return "set hostname";
    case 8: return "exec workload";
    case 9: return "wait for workload";
    case 10: return "read launch result";
    case 11: return "protect parent lifetime";
    default: return "unsupported platform";
    }
}
void scr_write_error(const char *message) { fputs(message, stderr); fputc('\n', stderr); }

#if defined(__linux__)
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <poll.h>
#include <sys/wait.h>

static int fail(scr_failure *failure, int stage, int error_number) {
    failure->stage = stage;
    failure->error_number = error_number;
    return -1;
}

/* Fixed-size protocol fits PIPE_BUF. No allocations or stdio in children. */
static void child_fail(int fd, int stage) {
    scr_failure failure = {stage, errno};
    ssize_t result;
    do { result = write(fd, &failure, sizeof(failure)); } while (result < 0 && errno == EINTR);
    _exit(125);
}

static int wait_child(pid_t pid, int *status) {
    pid_t result;
    do { result = waitpid(pid, status, 0); } while (result < 0 && errno == EINTR);
    return result < 0 ? -1 : 0;
}

static int shell_status(int status) {
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

int scr_namespace_run(const char *hostname, char *const argv[],
                      int32_t *exit_status, scr_failure *failure) {
    int channel[2];
    if (pipe2(channel, O_CLOEXEC) < 0) return fail(failure, 1, errno);
    /* Prepare everything needed by the forked processes in the parent. */
    size_t hostname_length = strlen(hostname);
    pid_t supervisor = getpid();
    pid_t launcher = fork();
    if (launcher < 0) {
        int saved = errno;
        close(channel[0]); close(channel[1]);
        return fail(failure, 2, saved);
    }
    if (launcher == 0) {
        close(channel[0]);
        /* Kill this branch if the foreground owner disappears, including the
         * race where it exits between fork and installing PDEATHSIG. */
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0) child_fail(channel[1], 11);
        if (getppid() != supervisor) _exit(125);
        if (unshare(CLONE_NEWUTS | CLONE_NEWPID | CLONE_NEWNS) < 0) child_fail(channel[1], 3);
        if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0) child_fail(channel[1], 4);
        /* PID 1 sees getppid() == 0 because its parent is outside its PID
         * namespace. An inherited pidfd closes that parent-death race. */
        int launcher_fd = (int)syscall(SYS_pidfd_open, getpid(), 0);
        if (launcher_fd < 0) child_fail(channel[1], 11);
        pid_t init = fork();
        if (init < 0) child_fail(channel[1], 5);
        if (init == 0) {
            if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0) child_fail(channel[1], 11);
            struct pollfd parent = {.fd = launcher_fd, .events = POLLIN};
            int ready;
            do { ready = poll(&parent, 1, 0); } while (ready < 0 && errno == EINTR);
            if (ready < 0) child_fail(channel[1], 11);
            if (ready > 0) _exit(125);
            close(launcher_fd);
            if (mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) < 0)
                child_fail(channel[1], 6);
            if (sethostname(hostname, hostname_length) < 0) child_fail(channel[1], 7);
            execv(argv[0], argv);
            child_fail(channel[1], 8);
        }
        close(launcher_fd);
        close(channel[1]);
        int status;
        if (wait_child(init, &status) < 0) _exit(125);
        _exit(shell_status(status));
    }
    close(channel[1]);
    scr_failure child_error = {0, 0};
    size_t received = 0;
    int read_error = 0;
    while (received < sizeof(child_error)) {
        ssize_t count = read(channel[0], (char *)&child_error + received, sizeof(child_error) - received);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { read_error = errno; break; }
        if (count == 0) break;
        received += (size_t)count;
    }
    close(channel[0]);
    int status;
    if (wait_child(launcher, &status) < 0) return fail(failure, 9, errno);
    if (read_error) return fail(failure, 10, read_error);
    if (received == sizeof(child_error)) { *failure = child_error; return -1; }
    if (received != 0) return fail(failure, 10, EIO);
    *exit_status = shell_status(status);
    return 0;
}
#else
int scr_namespace_run(const char *hostname, char *const argv[],
                      int32_t *exit_status, scr_failure *failure) {
    (void)hostname; (void)argv; (void)exit_status;
    failure->stage = 0;
    failure->error_number = ENOTSUP;
    return -1;
}
#endif
