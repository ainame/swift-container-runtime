/* Test fixture for scripts/rlimits-integration.sh, linked statically into
 * the BusyBox rootfs. It reports exact syscall results so that an
 * enforcement check never relies on a shell's error text, and so that an
 * unrelated failure or a timeout is reported as such, never as the limit.
 * Every mode writes one line per observation to stdout and exits 0 when the
 * observation itself succeeded (the expected values are checked by the
 * script), or 2 when the probe could not observe anything; the cpu mode
 * also exits 2 when its own timing check fails. */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static const char *const names[] = {
    "RLIMIT_CPU", "RLIMIT_FSIZE", "RLIMIT_DATA", "RLIMIT_STACK", "RLIMIT_CORE", "RLIMIT_RSS",
    "RLIMIT_NPROC", "RLIMIT_NOFILE", "RLIMIT_MEMLOCK", "RLIMIT_AS", "RLIMIT_LOCKS",
    "RLIMIT_SIGPENDING", "RLIMIT_MSGQUEUE", "RLIMIT_NICE", "RLIMIT_RTPRIO", "RLIMIT_RTTIME",
};

static void print_value(rlim_t value) {
    if (value == RLIM_INFINITY) printf(" unlimited");
    else printf(" %llu", (unsigned long long)value);
}

/* "NAME soft hard" for all sixteen resources, from getrlimit(2). */
static int limits(void) {
    for (int resource = 0; resource < 16; resource++) {
        struct rlimit limit;
        if (getrlimit(resource, &limit) != 0) {
            printf("%s error=%s\n", names[resource], strerror(errno));
            return 2;
        }
        printf("%s", names[resource]);
        print_value(limit.rlim_cur);
        print_value(limit.rlim_max);
        printf("\n");
    }
    return 0;
}

/* Opens /dev/null until open(2) fails: "nofile opened=N errno=NAME". Only
 * EMFILE is enforcement; the script rejects anything else. */
static int nofile(void) {
    int opened = 0;
    for (;;) {
        int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (fd < 0) break;
        if (++opened > 1 << 20) {
            printf("nofile opened=%d errno=none\n", opened);
            return 2;
        }
    }
    printf("nofile opened=%d errno=%s\n", opened, errno == EMFILE ? "EMFILE" : strerror(errno));
    return 0;
}

/* Writes BYTES to PATH in one call, then one more byte, with SIGXFSZ ignored
 * so that the kernel reports EFBIG: "fsize first=N second=errno size=S". */
static int fsize(const char *path, long bytes) {
    signal(SIGXFSZ, SIG_IGN);
    char *buffer = calloc(1, (size_t)bytes);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (buffer == NULL || fd < 0) {
        printf("fsize setup error=%s\n", strerror(errno));
        return 2;
    }
    ssize_t first = write(fd, buffer, (size_t)bytes);
    int first_errno = errno;
    ssize_t second = write(fd, buffer, 1);
    int second_errno = errno;
    off_t size = lseek(fd, 0, SEEK_END);
    printf("fsize first=%zd%s%s second=%s size=%lld\n", first, first < 0 ? " errno=" : "",
           first < 0 ? strerror(first_errno) : "",
           second < 0 ? (second_errno == EFBIG ? "EFBIG" : strerror(second_errno)) : "written",
           (long long)size);
    return 0;
}

static volatile sig_atomic_t received_sigxcpu;
static void on_sigxcpu(int signal_number) { (void)signal_number; received_sigxcpu = 1; }

/* Process CPU time as the kernel accounts it for RLIMIT_CPU (including the
 * runtime's setup before execve, which ran in this same process). */
static double cpu_seconds(void) {
    struct timespec used;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &used) != 0) return -1;
    return (double)used.tv_sec + (double)used.tv_nsec / 1e9;
}

/* Spins until SIGXCPU for a 1-second soft limit, bounded by a wall-clock
 * guard. Success, "cpu sigxcpu in-range", requires the signal and 0.8-2.0
 * seconds of CPU time when it arrived; the exact time varies with tick
 * granularity, so it is checked here rather than printed for comparison.
 * A missing signal or an implausible time prints the measurement and
 * exits 2, which the script treats as a failed run. */
static int cpu(int guard_seconds) {
    signal(SIGXCPU, on_sigxcpu);
    time_t deadline = time(NULL) + guard_seconds;
    volatile unsigned long spin = 0;
    while (!received_sigxcpu) {
        for (int i = 0; i < 1000000; i++) spin++;
        if (time(NULL) > deadline) {
            printf("cpu timeout used=%.3fs\n", cpu_seconds());
            return 2;
        }
    }
    double used = cpu_seconds();
    if (used < 0.8 || used > 2.0) {
        printf("cpu sigxcpu out-of-range used=%.3fs\n", used);
        return 2;
    }
    printf("cpu sigxcpu in-range\n");
    return 0;
}

/* Reserves SIZE MiB of address space with a real mmap(2) and releases it.
 * PROT_NONE with MAP_NORESERVE counts against RLIMIT_AS but is not charged
 * by overcommit accounting and touches no memory, so the outcome depends
 * on the limit alone. Returns "ok", "ENOMEM", or another error name. */
static const char *reserve(long mib) {
    size_t length = (size_t)mib << 20;
    void *mapping = mmap(NULL, length, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (mapping == MAP_FAILED) return errno == ENOMEM ? "ENOMEM" : strerror(errno);
    if (munmap(mapping, length) != 0) return "munmap-failed";
    return "ok";
}

/* "as limit=SOFT:HARD big=R small=R": the workload's own RLIMIT_AS from
 * getrlimit(2), then BIG and SMALL MiB reservations. Under a 1 GiB limit a
 * 1536 MiB reservation must fail with ENOMEM while 1 MiB still works. */
static int address_space(long big, long small) {
    struct rlimit limit;
    if (getrlimit(RLIMIT_AS, &limit) != 0) {
        printf("as getrlimit error=%s\n", strerror(errno));
        return 2;
    }
    printf("as limit=");
    if (limit.rlim_cur == RLIM_INFINITY) printf("unlimited"); else printf("%llu", (unsigned long long)limit.rlim_cur);
    printf(":");
    if (limit.rlim_max == RLIM_INFINITY) printf("unlimited"); else printf("%llu", (unsigned long long)limit.rlim_max);
    printf(" big=%s", reserve(big));
    printf(" small=%s\n", reserve(small));
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc == 2 && strcmp(argv[1], "limits") == 0) return limits();
    if (argc == 2 && strcmp(argv[1], "nofile") == 0) return nofile();
    if (argc == 4 && strcmp(argv[1], "fsize") == 0) return fsize(argv[2], atol(argv[3]));
    if (argc == 3 && strcmp(argv[1], "cpu") == 0) return cpu(atoi(argv[2]));
    if (argc == 4 && strcmp(argv[1], "as") == 0) return address_space(atol(argv[2]), atol(argv[3]));
    fprintf(stderr, "usage: rlimit-probe limits | nofile | fsize PATH BYTES | cpu GUARD | as BIG_MIB SMALL_MIB\n");
    return 2;
}
