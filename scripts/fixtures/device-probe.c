/* Real opens and mknod decisions, independent of the BPF bytecode builder. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

static int check_open(int flags, int denied) {
    errno = 0;
    int fd = open("/dev/sct-policy", flags);
    if (fd >= 0) close(fd);
    if (denied) return fd < 0 && errno == EPERM;
    /* An unallocated Unix98 slave has no backing terminal. ENXIO/EIO is
       the driver's result, proving the device filter allowed this open. */
    return fd >= 0 || errno == ENXIO || errno == EIO;
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int fd = open("/dev/null", O_RDWR);
    if (fd < 0 || write(fd, "x", 1) != 1) { perror("allowed null"); return 1; }
    close(fd);
    unlink("/dev/sct-policy");
    errno = 0;
    int result = mknod("/dev/sct-policy", S_IFCHR | 0666, makedev(137, 0));
    if (!strcmp(argv[1], "no-mknod")) {
        if (result != -1 || errno != EPERM) { perror("mknod must be denied"); return 1; }
    } else {
        if (result) { perror("allowed mknod"); return 1; }
        int read_denied = strcmp(argv[1], "allow") != 0;
        int write_denied = !strcmp(argv[1], "deny");
        if (!check_open(O_RDONLY, read_denied) || !check_open(O_WRONLY, write_denied)
            || !check_open(O_RDWR, read_denied || write_denied)) {
            perror("device open decision"); return 1;
        }
        if (unlink("/dev/sct-policy")) { perror("unlink"); return 1; }
    }
    printf("device policy %s enforced\n", argv[1]);
    return 0;
}
