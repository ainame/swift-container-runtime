/* Static probe for cpu-integration.sh. Linked statically so it runs in a
 * BusyBox rootfs. Only measurement lives here; expectations are in the script.
 *
 *   cpu-probe burn MS RELEASE
 *       Spin on integer work until this process has used MS milliseconds of
 *       CPU time (CLOCK_PROCESS_CPUTIME_ID), then print
 *       "burned cpu_us=C wall_us=W rounds=R checksum=X", where W is the
 *       CLOCK_MONOTONIC time the burn took. Then wait until the file RELEASE
 *       exists (the host reads the cgroup's cpu.stat meanwhile) and print
 *       "released"; RELEASE "-" does not wait.
 *
 * Exit status: 0 after "released"; 2 for a usage or clock error; 3 when the
 * burn has not reached MS after 40 s of wall-clock time ("burn timeout ...");
 * 4 when RELEASE has not appeared after 60 s ("release timeout"). A guard
 * expiring is never mistaken for a result.
 *
 * The work is a xorshift64 sequence whose state is stored to a volatile
 * global after every round and whose final value is printed, so an
 * optimizing compiler can neither drop nor precompute it: the CPU time is
 * really spent, which the script cross-checks with the kernel's usage_usec.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define ROUND_STEPS (1L << 16)

volatile uint64_t sink;

static int64_t now_us(clockid_t clock) {
    struct timespec value;
    if (clock_gettime(clock, &value) != 0) return -1;
    return (int64_t)value.tv_sec * 1000000 + value.tv_nsec / 1000;
}

static int burn(long milliseconds, const char *release) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int64_t cpu_start = now_us(CLOCK_PROCESS_CPUTIME_ID);
    int64_t wall_start = now_us(CLOCK_MONOTONIC);
    if (cpu_start < 0 || wall_start < 0) {
        printf("clock error\n");
        return 2;
    }
    uint64_t state = 0x9e3779b97f4a7c15ULL ^ (uint64_t)wall_start;
    int64_t target = (int64_t)milliseconds * 1000;
    int64_t cpu = 0;
    int64_t wall = 0;
    long rounds = 0;
    for (;;) {
        for (long step = 0; step < ROUND_STEPS; step++) {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
        }
        sink = state;
        rounds++;
        int64_t cpu_now = now_us(CLOCK_PROCESS_CPUTIME_ID);
        int64_t wall_now = now_us(CLOCK_MONOTONIC);
        if (cpu_now < 0 || wall_now < 0) {
            printf("clock error\n");
            return 2;
        }
        cpu = cpu_now - cpu_start;
        wall = wall_now - wall_start;
        if (cpu >= target) break;
        if (wall >= 40000000) {
            printf("burn timeout cpu_us=%lld wall_us=%lld\n", (long long)cpu, (long long)wall);
            return 3;
        }
    }
    printf("burned cpu_us=%lld wall_us=%lld rounds=%ld checksum=%llu\n", (long long)cpu, (long long)wall, rounds,
           (unsigned long long)sink);
    if (strcmp(release, "-") != 0) {
        /* 10 ms polls for up to 60 s. */
        struct timespec pause = {0, 10000000};
        long polls = 0;
        while (access(release, F_OK) != 0) {
            if (++polls > 6000) {
                printf("release timeout\n");
                return 4;
            }
            nanosleep(&pause, NULL);
        }
    }
    printf("released\n");
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "burn") == 0 && atol(argv[2]) > 0) return burn(atol(argv[2]), argv[3]);
    fprintf(stderr, "usage: cpu-probe burn MS RELEASE\n");
    return 2;
}
