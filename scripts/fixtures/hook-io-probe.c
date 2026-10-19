/* OCI hook I/O regressions: blocked stdin, output before input, and inherited
 * output after hook exit. Static so the same probe runs after pivot_root. */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

static void write_all(int fd, const void *bytes, size_t count) {
    const char *cursor = bytes;
    while (count) {
        ssize_t n = write(fd, cursor, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) _exit(90);
        cursor += n;
        count -= (size_t)n;
    }
}

static void record(const char *path, long value) {
    FILE *file = fopen(path, "w");
    if (!file || fprintf(file, "%ld\n", value) < 0 || fclose(file)) _exit(91);
}

int main(int argc, char **argv) {
    if (argc != 3) return 92;
    if (!strcmp(argv[1], "blocked")) {
        record(argv[2], (long)getpid());
        sleep(30); /* The hook's one-second timeout must interrupt stdin delivery. */
        return 93;
    }
    if (!strcmp(argv[1], "closed")) {
        close(STDIN_FILENO);
        write_all(STDERR_FILENO, "closed-input\n", 13);
        return 3;
    }
    char buffer[4096];
    memset(buffer, '#', sizeof(buffer));
    if (!strcmp(argv[1], "duplex")) {
        write_all(STDOUT_FILENO, "hook-output-first\n", 18);
        for (int i = 0; i < 64; ++i) write_all(STDOUT_FILENO, buffer, sizeof(buffer));
        long total = 0;
        for (;;) {
            ssize_t n = read(STDIN_FILENO, buffer, sizeof(buffer));
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) return 94;
            if (!n) break;
            total += n;
        }
        record(argv[2], total);
        return 3;
    }
    if (!strcmp(argv[1], "descendant")) {
        write_all(STDERR_FILENO, "hook-descendant\n", 16);
        pid_t child = fork();
        if (child < 0) return 95;
        if (!child) {
            close(STDIN_FILENO);
            /* Closing the runner's read end terminates this writer with SIGPIPE.
             * An alarm bounds the fixture itself if the runner never closes. */
            signal(SIGPIPE, SIG_DFL);
            alarm(15);
            for (;;) write_all(STDOUT_FILENO, buffer, sizeof(buffer));
        }
        record(argv[2], (long)child);
        return 3;
    }
    return 96;
}
