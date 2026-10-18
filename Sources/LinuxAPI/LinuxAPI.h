#ifndef SWIFT_CONTAINER_LINUX_API_H
#define SWIFT_CONTAINER_LINUX_API_H

#if defined(__linux__)
#include <fcntl.h>
#include <linux/bpf.h>
#include <stdint.h>
#include <linux/sched.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <sys/file.h>
/* inotify(7), which `events` uses to observe cgroup and state changes. */
#include <sys/inotify.h>
#include <sys/socket.h>
#include <sys/prctl.h>
#include <sys/resource.h>
/* struct statfs and fstatfs, which identify the cgroup v2 mount. */
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

/* libc exposes setns only with GNU feature macros; both glibc and musl provide it. */
extern int setns(int fd, int nstype);

/* glibc hides O_PATH without _GNU_SOURCE; musl always defines it. */
#if !defined(O_PATH) && defined(__O_PATH)
#define O_PATH __O_PATH
#endif

/* AT_EMPTY_PATH and AT_RECURSIVE are GNU extensions of libc's <fcntl.h>, and
 * the kernel's <linux/fcntl.h> redefines libc's struct flock, so it cannot be
 * included beside it. These AT_* bits are defined once for every architecture
 * in the kernel's include/uapi/linux/fcntl.h and are used only when libc
 * hides them. */
#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif
#ifndef AT_RECURSIVE
#define AT_RECURSIVE 0x8000
#endif

#include <linux/openat2.h>
#include <string.h>
#if defined(__GLIBC__)
#include <sys/mount.h>
#else
#include <linux/mount.h>
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

/* openat2(2), Linux 5.6. SYS_openat2 comes from <sys/syscall.h> and struct
 * open_how with the RESOLVE_* flags from the kernel's <linux/openat2.h>.
 * Opens a close-on-exec O_PATH handle for path resolved as if dirfd were the
 * root directory: absolute symlinks and ".." stay below it, and magic links
 * such as /proc/self/fd/N fail with ELOOP. The final component is followed
 * unless flags has O_NOFOLLOW. */
static inline int linux_open_path_in_root(int dirfd, const char *path, int flags) {
    struct open_how how;
    memset(&how, 0, sizeof how);
    how.flags = (__u64)(unsigned int)(flags | O_PATH | O_CLOEXEC);
    how.resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS;
    return (int)syscall(SYS_openat2, dirfd, path, &how, sizeof how);
}

/* The descriptor-based mount API (open_tree, move_mount, fsopen, fsconfig and
 * fsmount from Linux 5.2; mount_setattr from 5.12) has no musl wrappers. Its
 * constants and struct mount_attr come from glibc's <sys/mount.h> (2.36+) or,
 * for other C libraries, the kernel's <linux/mount.h>. Each adapter is one
 * fixed-signature system call on descriptors; no path is walked here. */

/* A detached close-on-exec bind of the file or directory open at fd (with
 * every mount below it when recursive), as open_tree(OPEN_TREE_CLONE). */
static inline int linux_clone_mount(int fd, int recursive) {
    unsigned int flags = OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC | AT_EMPTY_PATH | (recursive ? AT_RECURSIVE : 0);
    return (int)syscall(SYS_open_tree, fd, "", flags);
}

/* Attaches the detached mount at mount_fd onto the file open at target_fd. */
static inline int linux_attach_mount(int mount_fd, int target_fd) {
    return (int)syscall(SYS_move_mount, mount_fd, "", target_fd, "", MOVE_MOUNT_F_EMPTY_PATH | MOVE_MOUNT_T_EMPTY_PATH);
}

/* Sets MOUNT_ATTR_RDONLY on the mount whose root is open at fd and changes no
 * other mount attribute. */
static inline int linux_set_mount_readonly(int fd) {
    struct mount_attr attr;
    memset(&attr, 0, sizeof attr);
    attr.attr_set = MOUNT_ATTR_RDONLY;
    return (int)syscall(SYS_mount_setattr, fd, "", AT_EMPTY_PATH, &attr, sizeof attr);
}

/* A close-on-exec filesystem context for type, as fsopen(FSOPEN_CLOEXEC). */
static inline int linux_open_filesystem(const char *type) {
    return (int)syscall(SYS_fsopen, type, FSOPEN_CLOEXEC);
}

static inline int linux_set_filesystem_string(int fs_fd, const char *key, const char *value) {
    return (int)syscall(SYS_fsconfig, fs_fd, FSCONFIG_SET_STRING, key, value, 0);
}

static inline int linux_set_filesystem_flag(int fs_fd, const char *key) {
    return (int)syscall(SYS_fsconfig, fs_fd, FSCONFIG_SET_FLAG, key, NULL, 0);
}

static inline int linux_create_filesystem(int fs_fd) {
    return (int)syscall(SYS_fsconfig, fs_fd, FSCONFIG_CMD_CREATE, NULL, NULL, 0);
}

/* A detached close-on-exec mount of the created filesystem context, with
 * MOUNT_ATTR_RDONLY when readonly is non-zero. */
static inline int linux_mount_filesystem(int fs_fd, int readonly) {
    return (int)syscall(SYS_fsmount, fs_fd, FSMOUNT_CLOEXEC, readonly ? MOUNT_ATTR_RDONLY : 0U);
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

static inline int linux_unix_stream_socket(void) {
    return socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
}

/* The CMSG_* function-like macros are not imported into Swift. These expose
 * the two sizes unchanged, so each libc's own cmsghdr layout and alignment
 * apply; the message itself is assembled and sent in Swift. */
static inline size_t linux_cmsg_space(size_t length) {
    return CMSG_SPACE(length);
}

static inline size_t linux_cmsg_len(size_t length) {
    return CMSG_LEN(length);
}

static inline int linux_accept_cloexec(int fd) {
    return (int)syscall(SYS_accept4, fd, NULL, NULL, SOCK_CLOEXEC);
}

/* A peer hangup on a stream or seqpacket socket (GNU extension). */
#ifndef POLLRDHUP
#define POLLRDHUP 0x2000
#endif
/* bpf(2): keep the union ABI and pointer-to-u64 conversions out of Swift. */
static inline int linux_bpf_device_load(const uint8_t *instructions, size_t length,
                                       uint8_t *log, size_t log_length) {
    union bpf_attr attr = {0};
    attr.prog_type = BPF_PROG_TYPE_CGROUP_DEVICE;
    attr.expected_attach_type = BPF_CGROUP_DEVICE;
    attr.insn_cnt = (__u32)(length / sizeof(struct bpf_insn));
    attr.insns = (__u64)(uintptr_t)instructions;
    attr.license = (__u64)(uintptr_t)"Apache";
    attr.log_buf = (__u64)(uintptr_t)log;
    attr.log_size = (__u32)log_length;
    attr.log_level = 1;
    return (int)syscall(SYS_bpf, BPF_PROG_LOAD, &attr, sizeof(attr));
}
static inline int linux_bpf_device_attach(int program, int cgroup) {
    union bpf_attr attr = {0};
    attr.target_fd = (__u32)cgroup;
    attr.attach_bpf_fd = (__u32)program;
    attr.attach_type = BPF_CGROUP_DEVICE;
    attr.attach_flags = BPF_F_ALLOW_MULTI;
    return (int)syscall(SYS_bpf, BPF_PROG_ATTACH, &attr, sizeof(attr));
}
static inline int linux_bpf_device_detach(int program, int cgroup) {
    union bpf_attr attr = {0};
    attr.target_fd = (__u32)cgroup;
    attr.attach_bpf_fd = (__u32)program;
    attr.attach_type = BPF_CGROUP_DEVICE;
    return (int)syscall(SYS_bpf, BPF_PROG_DETACH, &attr, sizeof(attr));
}
static inline uint32_t linux_bpf_program_id(int program) {
    struct bpf_prog_info info = {0};
    union bpf_attr attr = {0};
    attr.info.bpf_fd = (__u32)program;
    attr.info.info_len = sizeof(info);
    attr.info.info = (__u64)(uintptr_t)&info;
    if (syscall(SYS_bpf, BPF_OBJ_GET_INFO_BY_FD, &attr, sizeof(attr)) < 0) return 0;
    return info.id;
}
static inline int linux_bpf_program_open(uint32_t id) {
    union bpf_attr attr = {0};
    attr.prog_id = id;
    return (int)syscall(SYS_bpf, BPF_PROG_GET_FD_BY_ID, &attr, sizeof(attr));
}
#endif

#endif
