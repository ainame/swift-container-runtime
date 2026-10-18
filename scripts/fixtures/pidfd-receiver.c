/* Test fixture for scripts/pidfd-socket-integration.sh, linked statically.
 * The --pidfd-socket listener, independent of the runtime's implementation.
 *
 * pidfd-receiver ADDRESS READY_FILE MODE
 *   Binds an AF_UNIX stream listener at ADDRESS (a leading '@' names an
 *   abstract socket), creates READY_FILE, and accepts one connection.
 *   MODE untouched: waits until the caller removes READY_FILE, then exits 0
 *     ("untouched") if no connection is pending, or 3 if one is.
 *   MODE signal or observe: receives exactly one message, which must carry a
 *     label and exactly one SCM_RIGHTS descriptor with no truncation, whose
 *     /proc/self/fd link names a pidfd, and prints "label LABEL" and
 *     "pid PID" from its fdinfo. MODE signal requires a positive PID and
 *     checks pidfd_send_signal(0) on the live process ("signal0 ok"); the
 *     caller must keep it alive until that line appears. MODE observe also
 *     accepts PID -1, which the kernel reports once a short-lived process
 *     has already been reaped. Both modes then poll the pidfd until the
 *     process exits ("exited"), wait up to 30 seconds for its reaping to make
 *     pidfd_send_signal(0) fail with ESRCH (a zombie still accepts signal 0)
 *     ("after-exit ESRCH"), and read the connection to EOF, which must bring
 *     no further bytes or descriptors ("eof").
 * pidfd-receiver --self-test
 *   Checks that the receive step itself rejects a message with no
 *   descriptor, two descriptors, or a truncated payload ("self-test ok").
 * Every failure prints a reason to stderr and exits 3. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>

#ifndef SYS_pidfd_send_signal
#define SYS_pidfd_send_signal 424
#endif

#define LABEL_CAPACITY 64
#define MAX_DESCRIPTORS 8

static void fail(const char *message) {
    fprintf(stderr, "pidfd-receiver: %s (errno %d: %s)\n", message, errno, strerror(errno));
    exit(3);
}

static void say(const char *line) {
    printf("%s\n", line);
    fflush(stdout);
}

static int send_signal(int pidfd, int signal_number) {
    return (int)syscall(SYS_pidfd_send_signal, pidfd, signal_number, NULL, 0U);
}

/* Receives one message. Returns its single descriptor, or -1 with the label
 * empty and a reason in *reason. Every received descriptor except the
 * returned one is closed. */
static int receive_one(int connection, char label[LABEL_CAPACITY], const char **reason) {
    char payload[LABEL_CAPACITY];
    union {
        struct cmsghdr header;
        char space[CMSG_SPACE(sizeof(int) * MAX_DESCRIPTORS)];
    } control;
    struct iovec vector = { payload, sizeof payload };
    struct msghdr message;
    memset(&message, 0, sizeof message);
    memset(&control, 0, sizeof control);
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.space;
    message.msg_controllen = sizeof control.space;
    ssize_t count;
    do {
        count = recvmsg(connection, &message, MSG_CMSG_CLOEXEC);
    } while (count < 0 && errno == EINTR);
    label[0] = 0;
    if (count < 0) {
        *reason = "recvmsg failed";
        return -1;
    }
    int descriptors[MAX_DESCRIPTORS];
    int received = 0, headers = 0, foreign = 0;
    for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header != NULL; header = CMSG_NXTHDR(&message, header)) {
        headers++;
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) {
            foreign++;
            continue;
        }
        size_t bytes = header->cmsg_len - CMSG_LEN(0);
        for (size_t offset = 0; offset + sizeof(int) <= bytes && received < MAX_DESCRIPTORS; offset += sizeof(int)) {
            memcpy(&descriptors[received++], CMSG_DATA(header) + offset, sizeof(int));
        }
    }
    *reason = NULL;
    if (count == 0) *reason = "connection closed without a message";
    else if (message.msg_flags & MSG_CTRUNC) *reason = "control data truncated";
    else if (message.msg_flags & MSG_TRUNC) *reason = "payload truncated";
    else if ((size_t)count >= sizeof payload) *reason = "label fills the payload buffer";
    else if (headers != 1 || foreign != 0) *reason = "expected exactly one SCM_RIGHTS header";
    else if (received != 1) *reason = "expected exactly one descriptor";
    else if (memchr(payload, 0, (size_t)count) != NULL) *reason = "label contains NUL";
    if (*reason != NULL) {
        for (int index = 0; index < received; index++) close(descriptors[index]);
        return -1;
    }
    memcpy(label, payload, (size_t)count);
    label[count] = 0;
    return descriptors[0];
}

/* The "Pid:" field of a pidfd's fdinfo, or -2 when it has none. */
static long fdinfo_pid(int descriptor) {
    char path[64];
    snprintf(path, sizeof path, "/proc/self/fdinfo/%d", descriptor);
    FILE *file = fopen(path, "re");
    if (file == NULL) fail("open fdinfo");
    char line[256];
    long pid = -2;
    while (fgets(line, sizeof line, file) != NULL) {
        if (strncmp(line, "Pid:", 4) == 0) pid = strtol(line + 4, NULL, 10);
    }
    fclose(file);
    return pid;
}

static void self_send(int socket, const char *payload, size_t length, const int *descriptors, int count) {
    union {
        struct cmsghdr header;
        char space[CMSG_SPACE(sizeof(int) * 2)];
    } control;
    struct iovec vector = { (void *)payload, length };
    struct msghdr message;
    memset(&message, 0, sizeof message);
    memset(&control, 0, sizeof control);
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    if (count > 0) {
        message.msg_control = control.space;
        message.msg_controllen = CMSG_SPACE(sizeof(int) * (size_t)count);
        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
        header->cmsg_level = SOL_SOCKET;
        header->cmsg_type = SCM_RIGHTS;
        header->cmsg_len = CMSG_LEN(sizeof(int) * (size_t)count);
        memcpy(CMSG_DATA(header), descriptors, sizeof(int) * (size_t)count);
    }
    if (sendmsg(socket, &message, MSG_NOSIGNAL) != (ssize_t)length) fail("self-test sendmsg");
}

static void self_expect(int expect_success, const char *name, const char *payload, size_t length, int count) {
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) != 0) fail("self-test socketpair");
    int descriptors[2] = { 0, 1 };
    self_send(pair[0], payload, length, descriptors, count);
    char label[LABEL_CAPACITY];
    const char *reason = NULL;
    int received = receive_one(pair[1], label, &reason);
    if (expect_success != (received >= 0)) {
        fprintf(stderr, "pidfd-receiver: self-test %s: %s\n", name,
                reason != NULL ? reason : "accepted");
        exit(3);
    }
    if (received >= 0) close(received);
    close(pair[0]);
    close(pair[1]);
}

static int self_test(void) {
    char oversized[LABEL_CAPACITY * 2];
    memset(oversized, 'x', sizeof oversized);
    self_expect(1, "one descriptor", "standard", 8, 1);
    self_expect(0, "no descriptor", "standard", 8, 0);
    self_expect(0, "two descriptors", "standard", 8, 2);
    self_expect(0, "oversized label", oversized, sizeof oversized, 1);
    say("self-test ok");
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return self_test();
    if (argc != 4) {
        fprintf(stderr, "usage: pidfd-receiver ADDRESS READY_FILE untouched|signal|observe\n");
        return 2;
    }
    const char *mode = argv[3];
    if (strcmp(mode, "untouched") != 0 && strcmp(mode, "signal") != 0 && strcmp(mode, "observe") != 0) {
        fprintf(stderr, "pidfd-receiver: unknown mode %s\n", mode);
        return 2;
    }

    /* Listen, then announce readiness through the file. */
    struct sockaddr_un address;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    size_t length = strlen(argv[1]);
    if (length == 0 || length >= sizeof address.sun_path) fail("address length");
    memcpy(address.sun_path, argv[1], length);
    socklen_t address_length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + length + 1);
    if (argv[1][0] == '@') {
        address.sun_path[0] = 0;
        address_length--;
    }
    int listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (listener < 0) fail("socket");
    if (bind(listener, (struct sockaddr *)&address, address_length) != 0) fail("bind");
    if (listen(listener, 4) != 0) fail("listen");
    int ready = open(argv[2], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (ready < 0) fail("create ready file");
    close(ready);

    if (strcmp(mode, "untouched") == 0) {
        while (access(argv[2], F_OK) == 0) usleep(20000);
        struct pollfd pending = { listener, POLLIN, 0 };
        int ready_count;
        while ((ready_count = poll(&pending, 1, 0)) < 0) {
            if (errno != EINTR) fail("poll listener");
        }
        if (ready_count > 0) {
            fprintf(stderr, "pidfd-receiver: a connection was made\n");
            return 3;
        }
        say("untouched");
        return 0;
    }

    int connection;
    do {
        connection = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
    } while (connection < 0 && errno == EINTR);
    if (connection < 0) fail("accept");
    close(listener);

    /* The one message: label and pidfd. */
    char label[LABEL_CAPACITY];
    const char *reason = NULL;
    int pidfd = receive_one(connection, label, &reason);
    if (pidfd < 0) {
        fprintf(stderr, "pidfd-receiver: %s\n", reason);
        return 3;
    }
    printf("label %s\n", label);
    /* "anon_inode:[pidfd]", or "pidfd:[INODE]" on kernels with pidfs. */
    char link_path[64], link[128];
    snprintf(link_path, sizeof link_path, "/proc/self/fd/%d", pidfd);
    ssize_t link_length = readlink(link_path, link, sizeof link - 1);
    if (link_length < 0) fail("readlink of the received descriptor");
    link[link_length] = 0;
    if (strcmp(link, "anon_inode:[pidfd]") != 0 && strncmp(link, "pidfd:", 6) != 0) {
        fprintf(stderr, "pidfd-receiver: received %s, not a pidfd\n", link);
        return 3;
    }
    long pid = fdinfo_pid(pidfd);
    int observing = strcmp(mode, "observe") == 0;
    if (pid == -2) fail("the pidfd has no Pid field");
    if (pid == 0 || pid < -1 || (pid == -1 && !observing)) {
        fprintf(stderr, "pidfd-receiver: pidfd names PID %ld, not a live process\n", pid);
        return 3;
    }
    printf("pid %ld\n", pid);
    fflush(stdout);
    if (strcmp(mode, "signal") == 0) {
        if (send_signal(pidfd, 0) != 0) fail("pidfd_send_signal(0) on the live process");
        say("signal0 ok");
    }

    /* Exit through the pidfd, then the stale pidfd must not signal anything. */
    struct pollfd process = { pidfd, POLLIN, 0 };
    while (poll(&process, 1, -1) < 0) {
        if (errno != EINTR) fail("poll pidfd");
    }
    say("exited");
    /* Readable means exited; ESRCH needs the zombie reaped by its parent or
     * subreaper, which the caller provides. */
    for (int attempt = 0;; attempt++) {
        if (send_signal(pidfd, 0) != 0) {
            if (errno == ESRCH) break;
            fail("pidfd_send_signal(0) after exit");
        }
        if (attempt == 1500) fail("the exited process was not reaped within 30 seconds");
        usleep(20000);
    }
    say("after-exit ESRCH");
    close(pidfd);

    /* Nothing else may follow on the connection. */
    char extra_label[LABEL_CAPACITY];
    int extra = receive_one(connection, extra_label, &reason);
    if (extra >= 0 || reason == NULL || strcmp(reason, "connection closed without a message") != 0) {
        fprintf(stderr, "pidfd-receiver: data after the pidfd message: %s\n", reason != NULL ? reason : "another pidfd");
        return 3;
    }
    say("eof");
    close(connection);
    return 0;
}
