/* Direct syscall: avoid libc caching or a library fallback hiding the filter. */
#define _GNU_SOURCE
#include <errno.h>
#include <stddef.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc >= 3 && !strcmp(argv[1], "deny-load")) {
        struct sock_filter filter[] = {
            BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
            BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_seccomp, 0, 3),
            BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
            BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SECCOMP_SET_MODE_FILTER, 0, 1),
            BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
            BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog program = {.len = sizeof(filter) / sizeof(filter[0]), .filter = filter};
        if (syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &program)) { perror("outer filter"); return 1; }
        execvp(argv[2], argv + 2);
        perror("wrapper exec");
        return 1;
    }
    if ((argc == 4 && !strcmp(argv[1], "argument")) || (argc == 5 && !strcmp(argv[1], "arguments"))) {
        unsigned long long value = strtoull(argv[2], NULL, 0);
        errno = 0;
        long result = syscall(SYS_getpgid, value, argc == 5 ? strtoull(argv[3], NULL, 0) : 0);
        int denied = result == -1 && errno == EACCES;
        if (denied != !strcmp(argv[argc - 1], "denied")) {
            fprintf(stderr, "getpgid(%llu): result=%ld errno=%d\n", value, result, errno);
            return 1;
        }
        puts(denied ? "argument: EACCES" : "argument: allowed");
        return 0;
    }
    if (argc != 2) return 2;
    if (!strncmp(argv[1], "identity-", 9)) {
        errno = 0;
        long result = syscall(SYS_getpgid, 0);
        int expected = !strcmp(argv[1], "identity-denied") ? EACCES : !strcmp(argv[1], "identity-enosys") ? ENOSYS : 0;
        if ((expected && (result != -1 || errno != expected)) || (!expected && result < 0)) {
            fprintf(stderr, "getpgid: result=%ld errno=%d expected=%d\n", result, errno, expected); return 1;
        }
        puts(expected == EACCES ? "getpgid: EACCES" : expected == ENOSYS ? "getpgid: ENOSYS" : "getpgid: allowed");
        return 0;
    }
    char path[4096];
    errno = 0;
    long result = syscall(SYS_getcwd, path, sizeof(path));
    if (!strcmp(argv[1], "allowed")) {
        if (result <= 0 || path[0] != '/') { perror("getcwd allowed"); return 1; }
        puts("getcwd: allowed");
    } else if (!strcmp(argv[1], "denied")) {
        if (result != -1 || errno != EACCES) { fprintf(stderr, "getcwd: result=%ld errno=%d, expected EACCES\n", result, errno); return 1; }
        puts("getcwd: EACCES");
    } else return 2;
    return 0;
}
