/* Test fixture for scripts/console-integration.sh, linked statically.
 * The --console-socket listener, independent of the runtime's implementation.
 *
 * console-receiver ADDRESS READY_FILE [INPUT]
 *   Binds an AF_UNIX stream listener at ADDRESS, creates READY_FILE, accepts
 *   one connection and receives one message carrying exactly one SCM_RIGHTS
 *   descriptor, which must be a pseudoterminal master (TIOCGPTN). Prints
 *   "winsize ROWS COLS" from TIOCGWINSZ, then copies the terminal's output to
 *   stdout until EIO, which the kernel reports once every peer has closed.
 *   When the output contains "INPUT?", writes INPUT and a newline once.
 *   Everything must finish within 30 seconds.
 * Every failure prints a reason to stderr and exits 3. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static void fail(const char *message) {
    fprintf(stderr, "console-receiver: %s (errno %d: %s)\n", message, errno, strerror(errno));
    exit(3);
}

/* Receives one message with exactly one descriptor and no truncation. */
static int receive_descriptor(int connection) {
    char payload[256];
    union {
        struct cmsghdr header;
        char space[CMSG_SPACE(sizeof(int) * 4)];
    } control;
    struct iovec vector = {.iov_base = payload, .iov_len = sizeof payload};
    struct msghdr message = {0};
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.space;
    message.msg_controllen = sizeof control.space;
    ssize_t count = recvmsg(connection, &message, MSG_CMSG_CLOEXEC);
    if (count < 0) fail("recvmsg");
    if (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) { errno = EMSGSIZE; fail("truncated message"); }
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    if (!header || header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS
        || header->cmsg_len != CMSG_LEN(sizeof(int)) || CMSG_NXTHDR(&message, header)) {
        errno = EPROTO;
        fail("expected exactly one SCM_RIGHTS descriptor");
    }
    int descriptor;
    memcpy(&descriptor, CMSG_DATA(header), sizeof descriptor);
    return descriptor;
}

int main(int argc, char **argv) {
    if (argc != 3 && argc != 4) { errno = EINVAL; fail("usage: console-receiver ADDRESS READY_FILE [INPUT]"); }
    alarm(30);
    int listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (listener < 0) fail("socket");
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (strlen(argv[1]) >= sizeof address.sun_path) { errno = ENAMETOOLONG; fail("address"); }
    strcpy(address.sun_path, argv[1]);
    if (bind(listener, (struct sockaddr *)&address, sizeof address) < 0) fail("bind");
    if (listen(listener, 1) < 0) fail("listen");
    int ready = open(argv[2], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (ready < 0) fail("create ready file");
    close(ready);
    int connection = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
    if (connection < 0) fail("accept");
    int master = receive_descriptor(connection);
    unsigned int number;
    if (ioctl(master, TIOCGPTN, &number) < 0) fail("descriptor is not a pseudoterminal master");
    struct winsize size;
    if (ioctl(master, TIOCGWINSZ, &size) < 0) fail("TIOCGWINSZ");
    printf("winsize %u %u\n", size.ws_row, size.ws_col);
    fflush(stdout);

    // Copy output; answer the first prompt. "INPUT?" may span two reads.
    const char *input = argc == 4 ? argv[3] : NULL;
    char window[8] = {0};
    char buffer[4096];
    for (;;) {
        ssize_t count = read(master, buffer, sizeof buffer);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && errno == EIO) break;
        if (count < 0) fail("read terminal");
        if (count == 0) break;
        if (fwrite(buffer, 1, (size_t)count, stdout) != (size_t)count) fail("write output");
        fflush(stdout);
        for (ssize_t index = 0; input && index < count; index++) {
            memmove(window, window + 1, sizeof window - 2);
            window[sizeof window - 2] = buffer[index];
            if (strstr(window, "INPUT?")) {
                size_t length = strlen(input);
                if (write(master, input, length) != (ssize_t)length || write(master, "\n", 1) != 1) fail("write input");
                input = NULL;
            }
        }
    }
    return 0;
}
