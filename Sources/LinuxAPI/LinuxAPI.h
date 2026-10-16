#ifndef SWIFT_CONTAINER_LINUX_API_H
#define SWIFT_CONTAINER_LINUX_API_H

#if defined(__linux__)
#include <fcntl.h>
#include <linux/sched.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

/* glibc hides O_PATH without _GNU_SOURCE; musl always defines it. */
#if !defined(O_PATH) && defined(__O_PATH)
#define O_PATH __O_PATH
#endif

/* This GNU extension may be hidden by the libc overlay's feature selection.
 * It is also available in musl. */
extern int unshare(int flags);

/* These C ellipsis APIs have no va_list entry points. Keep the adapters fixed-signature;
 * all process setup and supervision remain in Swift. */
static inline int linux_set_parent_death_signal(int signal_number) {
    return prctl(PR_SET_PDEATHSIG, (unsigned long)signal_number, 0UL, 0UL, 0UL);
}

static inline int linux_pidfd_open(pid_t pid) {
    return (int)syscall(SYS_pidfd_open, pid, 0U);
}

/* glibc has no pivot_root wrapper. */
static inline int linux_pivot_root(const char *new_root, const char *put_old) {
    return (int)syscall(SYS_pivot_root, new_root, put_old);
}

/* close_range(2) arrived in Linux 5.9; CLOSE_RANGE_CLOEXEC in 5.11. SYS_close_range
 * must come from <sys/syscall.h>. The stable flag value is defined here so the
 * header does not depend on <linux/close_range.h>. */
#ifndef CLOSE_RANGE_CLOEXEC
#define CLOSE_RANGE_CLOEXEC (1U << 2)
#endif

/* Marks every descriptor >= first close-on-exec. */
static inline int linux_mark_descriptors_cloexec(unsigned int first) {
    return (int)syscall(SYS_close_range, first, ~0U, CLOSE_RANGE_CLOEXEC);
}

/* Opens a close-on-exec O_PATH handle relative to dirfd. openat is variadic. */
static inline int linux_open_path(int dirfd, const char *path, int flags) {
    return openat(dirfd, path, flags | O_PATH | O_CLOEXEC);
}
#endif

#endif
