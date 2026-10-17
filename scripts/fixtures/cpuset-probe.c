/* Test-only affinity probe. The runtime's cpuset must constrain this
 * process before exec; sched_setaffinity cannot escape that constraint. */
#define _GNU_SOURCE
#include <sched.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int allowed = atoi(argv[1]), outside = atoi(argv[2]);
    if (allowed < 0 || allowed >= CPU_SETSIZE || outside >= CPU_SETSIZE) return 2;
    cpu_set_t mask;
    CPU_ZERO(&mask);
    if (sched_getaffinity(0, sizeof(mask), &mask) != 0) return 3;
    if (CPU_COUNT(&mask) != 1 || !CPU_ISSET(allowed, &mask)) return 4;

    /* An allowed affinity succeeds; an entirely excluded mask must fail. */
    CPU_ZERO(&mask);
    CPU_SET(allowed, &mask);
    if (sched_setaffinity(0, sizeof(mask), &mask) != 0) return 5;
    puts("allowed affinity ok");
    if (outside >= 0) {
        CPU_ZERO(&mask);
        CPU_SET(outside, &mask);
        errno = 0;
        if (sched_setaffinity(0, sizeof(mask), &mask) != -1 || errno != EINVAL) return 6;
        puts("outside affinity EINVAL");
    }
    return 0;
}
