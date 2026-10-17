/* Static probe for cgroup-integration.sh. Linked statically so it runs in a
 * BusyBox rootfs. Only measurement lives here; expectations are in the script.
 *
 *   cgroup-probe fork MAX     fork paused children until fork fails or MAX
 *                             succeed; print "forked N errno NAME" (NAME is
 *                             "none" when MAX was reached), then reap them.
 *   cgroup-probe alloc MIB    map and touch MIB MiB one MiB at a time,
 *                             printing "allocated N" after each; then "done".
 *   cgroup-probe hold MIB     like alloc, then print "holding" and sleep.
 *
 * Allocations are private anonymous mmaps whose every page is written
 * through a volatile pointer, and each mapping is kept in a global table, so
 * an optimizing compiler can neither drop the stores nor the mappings: the
 * memory is really charged to the cgroup.
 */
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define CHUNK (1L << 20)
#define PAGE 4096L
#define MAX_CHUNKS 65536

static const char *errno_name(int code) {
    switch (code) {
    case EAGAIN: return "EAGAIN";
    case ENOMEM: return "ENOMEM";
    case EPERM: return "EPERM";
    default: return "other";
    }
}

static int fork_children(long max) {
    pid_t children[4096];
    long count = 0;
    int failure = 0;
    if (max > 4096) max = 4096;
    while (count < max) {
        pid_t child = fork();
        if (child < 0) {
            failure = errno;
            break;
        }
        if (child == 0) {
            pause();
            _exit(0);
        }
        children[count++] = child;
    }
    printf("forked %ld errno %s\n", count, failure ? errno_name(failure) : "none");
    fflush(stdout);
    for (long index = 0; index < count; index++) kill(children[index], SIGKILL);
    for (long index = 0; index < count; index++) waitpid(children[index], NULL, 0);
    return 0;
}

/* Every mapping stays reachable for the life of the process. */
char *volatile chunks[MAX_CHUNKS];

static int allocate(long mebibytes, int hold) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (mebibytes > MAX_CHUNKS) mebibytes = MAX_CHUNKS;
    for (long index = 1; index <= mebibytes; index++) {
        char *chunk = mmap(NULL, CHUNK, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (chunk == MAP_FAILED) {
            printf("mmap failed after %ld errno %s\n", index - 1, errno_name(errno));
            return 3;
        }
        chunks[index - 1] = chunk;
        /* Write each page with nonzero data so it is faulted in and charged. */
        volatile char *pages = chunk;
        for (long offset = 0; offset < CHUNK; offset += PAGE) pages[offset] = (char)((index & 0x7f) | 1);
        printf("allocated %ld\n", index);
    }
    if (hold) {
        printf("holding\n");
        for (;;) pause();
    }
    printf("done\n");
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "fork") == 0) return fork_children(atol(argv[2]));
    if (argc == 3 && strcmp(argv[1], "alloc") == 0) return allocate(atol(argv[2]), 0);
    if (argc == 3 && strcmp(argv[1], "hold") == 0) return allocate(atol(argv[2]), 1);
    fprintf(stderr, "usage: cgroup-probe fork MAX | alloc MIB | hold MIB\n");
    return 2;
}
