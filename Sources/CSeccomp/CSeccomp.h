#ifndef SCT_SECCOMP_H
#define SCT_SECCOMP_H
#include <seccomp.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/syscall.h>
#include <linux/memfd.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

/* Export before fork: no library allocations or temporary files in the child. */
static inline int sct_seccomp_export(scmp_filter_ctx context) {
    int fd = syscall(SYS_memfd_create, "sct-seccomp", MFD_CLOEXEC);
    if (fd < 0) return -errno;
    int result = seccomp_export_bpf(context, fd);
    if (result < 0) { close(fd); return result; }
    if (lseek(fd, 0, SEEK_SET) < 0) { int error = errno; close(fd); return -error; }
    return fd;
}
/* A byte buffer need not be aligned for sock_filter. Copy into aligned storage. */
static inline int sct_seccomp_install(const unsigned char *bytes, size_t size, unsigned int flags) {
    struct sock_filter instructions[4096];
    if (!size || size % sizeof(struct sock_filter) || size > sizeof(instructions)) { errno = EINVAL; return -1; }
    memcpy(instructions, bytes, size);
    struct sock_fprog program = { .len = size / sizeof(struct sock_filter), .filter = instructions };
    long result = syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, flags, &program);
    /* TSYNC can return a positive unsynchronized TID instead of setting errno. */
    if (result > 0) { errno = EBUSY; return -1; }
    return (int)result;
}
#endif
