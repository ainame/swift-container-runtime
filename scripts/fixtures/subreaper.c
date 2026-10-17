/* Test fixture for scripts/lifecycle-integration.sh: the caller that runc
 * requires of detached processes (runc docs/terminals.md). It marks itself
 * PR_SET_CHILD_SUBREAPER, runs COMMAND, and reaps every process reparented
 * to it while COMMAND runs. After COMMAND exits it reaps what has already
 * exited without waiting for anything still alive, so a leaked process
 * cannot hang the check, and exits with COMMAND's shell-style status. */
#include <errno.h>
#include <stdio.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: subreaper COMMAND [ARG...]\n");
        return 2;
    }
    if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0) {
        perror("subreaper: PR_SET_CHILD_SUBREAPER");
        return 125;
    }
    pid_t command = fork();
    if (command < 0) {
        perror("subreaper: fork");
        return 125;
    }
    if (command == 0) {
        execvp(argv[1], argv + 1);
        perror(argv[1]);
        _exit(127);
    }

    /* Reap the command and every orphan until the command has exited. */
    int result = -1;
    while (result < 0) {
        int status;
        pid_t pid = waitpid(-1, &status, 0);
        if (pid < 0) {
            if (errno == EINTR) continue;
            perror("subreaper: waitpid");
            return 125;
        }
        if (pid == command) result = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    }

    /* Then collect zombies that are already present, without blocking. */
    int status;
    while (waitpid(-1, &status, WNOHANG) > 0) {}
    return result;
}
