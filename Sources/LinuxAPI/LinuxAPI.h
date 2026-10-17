#ifndef SWIFT_CONTAINER_LINUX_API_H
#define SWIFT_CONTAINER_LINUX_API_H

#if defined(__linux__)
#include <fcntl.h>
#include <linux/sched.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/prctl.h>
#include <sys/resource.h>
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

static inline int linux_set_no_new_privileges(void) {
    return prctl(PR_SET_NO_NEW_PRIVS, 1UL, 0UL, 0UL, 0UL);
}

/* Capability adapters. The sets and their order are decided in Swift; these
 * only expose the variadic prctl operations and the capset(2) syscall, which
 * neither libc wraps without libcap. Stable values from <linux/prctl.h> and
 * <linux/capability.h> back older headers. */
#ifndef PR_CAPBSET_READ
#define PR_CAPBSET_READ 23
#endif
#ifndef PR_CAPBSET_DROP
#define PR_CAPBSET_DROP 24
#endif
#ifndef PR_CAP_AMBIENT
#define PR_CAP_AMBIENT 47
#endif
#ifndef PR_CAP_AMBIENT_RAISE
#define PR_CAP_AMBIENT_RAISE 2
#endif
#ifndef PR_CAP_AMBIENT_CLEAR_ALL
#define PR_CAP_AMBIENT_CLEAR_ALL 4
#endif

/* 1 if the capability is in the bounding set, 0 if not, -1 with errno. */
static inline int linux_read_bounding_capability(int capability) {
    return prctl(PR_CAPBSET_READ, (unsigned long)capability, 0UL, 0UL, 0UL);
}

/* Requires CAP_SETPCAP in the effective set. */
static inline int linux_drop_bounding_capability(int capability) {
    return prctl(PR_CAPBSET_DROP, (unsigned long)capability, 0UL, 0UL, 0UL);
}

static inline int linux_set_keep_capabilities(int keep) {
    return prctl(PR_SET_KEEPCAPS, (unsigned long)keep, 0UL, 0UL, 0UL);
}

static inline int linux_clear_ambient_capabilities(void) {
    return prctl(PR_CAP_AMBIENT, (unsigned long)PR_CAP_AMBIENT_CLEAR_ALL, 0UL, 0UL, 0UL);
}

static inline int linux_raise_ambient_capability(int capability) {
    return prctl(PR_CAP_AMBIENT, (unsigned long)PR_CAP_AMBIENT_RAISE, (unsigned long)capability, 0UL, 0UL);
}

/* capset(2) for the calling thread with _LINUX_CAPABILITY_VERSION_3, whose
 * data is two 32-bit words per set (capabilities 0-31, then 32-63). The
 * layouts match struct __user_cap_header_struct and __user_cap_data_struct. */
static inline int linux_set_capabilities(
    unsigned long long effective, unsigned long long permitted, unsigned long long inheritable
) {
    struct { unsigned int version; int pid; } header = { 0x20080522U, 0 };
    struct { unsigned int effective, permitted, inheritable; } data[2] = {
        { (unsigned int)effective, (unsigned int)permitted, (unsigned int)inheritable },
        { (unsigned int)(effective >> 32), (unsigned int)(permitted >> 32), (unsigned int)(inheritable >> 32) },
    };
    return (int)syscall(SYS_capset, &header, data);
}

/* Resource limit adapters. Which limits are set, and when, is decided in
 * Swift. prlimit64(2) on the calling process takes 64-bit values on every
 * architecture, so neither libc's rlim_t width nor glibc's GNU-only prlimit
 * prototype matters; ~0ULL is RLIM64_INFINITY. The resource numbers are
 * Swift's ResourceLimit.Resource.number values, checked here against the
 * target headers. */
_Static_assert(RLIMIT_CPU == 0 && RLIMIT_FSIZE == 1 && RLIMIT_DATA == 2 && RLIMIT_STACK == 3,
               "ResourceLimit.Resource.number assumes the generic Linux rlimit numbers");
_Static_assert(RLIMIT_CORE == 4 && RLIMIT_RSS == 5 && RLIMIT_NPROC == 6 && RLIMIT_NOFILE == 7,
               "ResourceLimit.Resource.number assumes the generic Linux rlimit numbers");
_Static_assert(RLIMIT_MEMLOCK == 8 && RLIMIT_AS == 9 && RLIMIT_LOCKS == 10 && RLIMIT_SIGPENDING == 11,
               "ResourceLimit.Resource.number assumes the generic Linux rlimit numbers");
_Static_assert(RLIMIT_MSGQUEUE == 12 && RLIMIT_NICE == 13 && RLIMIT_RTPRIO == 14 && RLIMIT_RTTIME == 15,
               "ResourceLimit.Resource.number assumes the generic Linux rlimit numbers");

/* Sets the calling process's limit; 0 or -1 with errno. */
static inline int linux_set_resource_limit(int resource, unsigned long long soft, unsigned long long hard) {
    struct { unsigned long long cur, max; } updated = { soft, hard };
    return (int)syscall(SYS_prlimit64, 0, resource, &updated, NULL);
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

/* Opens a close-on-exec descriptor relative to dirfd with an explicit mode. */
static inline int linux_open_at(int dirfd, const char *path, int flags, unsigned int mode) {
    return openat(dirfd, path, flags | O_CLOEXEC, (mode_t)mode);
}

/* pidfd_send_signal(2), Linux 5.1. Use the target headers' syscall number. */
static inline int linux_pidfd_send_signal(int pidfd, int signal_number) {
    return (int)syscall(SYS_pidfd_send_signal, pidfd, signal_number, NULL, 0U);
}

/* glibc imports SOCK_* as enum members and hides accept4 without _GNU_SOURCE
 * (its GNU prototype also differs from musl's); these fixed-signature adapters
 * give both libcs one close-on-exec spelling. */
static inline int linux_unix_seqpacket_socket(void) {
    return socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
}

static inline int linux_unix_stream_socketpair(int descriptors[2]) {
    return socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, descriptors);
}

static inline int linux_accept_cloexec(int fd) {
    return (int)syscall(SYS_accept4, fd, NULL, NULL, SOCK_CLOEXEC);
}

/* A peer hangup on a stream or seqpacket socket (GNU extension). */
#ifndef POLLRDHUP
#define POLLRDHUP 0x2000
#endif
#endif

#endif
