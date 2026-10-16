#ifndef SWIFT_CONTAINER_LINUX_API_H
#define SWIFT_CONTAINER_LINUX_API_H

#if defined(__linux__)
#include <linux/sched.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

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
#endif

#endif
