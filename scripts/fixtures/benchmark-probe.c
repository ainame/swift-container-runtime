// Linux-only measurement parent. Compile before sampling; unlike a Python fork,
// its small address space does not impose the Python interpreter's RSS floor on
// the runtime child. wait4 reports the largest process high-water mark, not a sum.
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    struct timespec start, end;
    if (clock_gettime(CLOCK_MONOTONIC, &start) != 0) return 2;
    pid_t child = fork();
    if (child < 0) return 2;
    if (child == 0) {
        // Reserve stdout for the parent's measurement JSON.
        if (freopen("/dev/null", "w", stdout) == NULL) _exit(126);
        execv(argv[1], &argv[1]);
        perror("exec runtime");
        _exit(127);
    }
    int status;
    struct rusage usage;
    pid_t waited;
    do { waited = wait4(child, &status, 0, &usage); } while (waited < 0 && errno == EINTR);
    if (waited < 0 || clock_gettime(CLOCK_MONOTONIC, &end) != 0) return 2;
    double elapsed = (end.tv_sec - start.tv_sec) * 1000.0 + (end.tv_nsec - start.tv_nsec) / 1e6;
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    printf("{\"elapsed_ms\":%.6f,\"max_rss_kib\":%ld,\"exit_code\":%d}\n",
           elapsed, usage.ru_maxrss, code);
    return code;
}
