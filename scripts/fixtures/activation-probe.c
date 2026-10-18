/* Test fixture for scripts/socket-activation-integration.sh, linked
 * statically into the rootfs. It prints its LISTEN_* variables and its open
 * descriptors 0-63, reads one line from descriptor 4 when open, and, when
 * descriptor 3 is a listening socket, serves one request on it: it prints
 * "accepting", reads a line, answers "pong LINE", and prints "served LINE". */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void show(const char *name) {
    const char *value = getenv(name);
    printf("%s %s\n", name, value ? value : "(unset)");
}

int main(void) {
    show("LISTEN_FDS");
    show("LISTEN_PID");
    show("LISTEN_FDNAMES");
    printf("fds");
    for (int fd = 0; fd < 64; fd++) {
        if (fcntl(fd, F_GETFD) >= 0) printf(" %d", fd);
    }
    printf("\n");
    if (fcntl(4, F_GETFD) >= 0) {
        char line[64] = {0};
        ssize_t n = read(4, line, sizeof line - 1);
        if (n > 0) {
            line[strcspn(line, "\n")] = 0;
            printf("fd4 %s\n", line);
        }
    }
    int listening = 0;
    socklen_t size = sizeof listening;
    if (getsockopt(3, SOL_SOCKET, SO_ACCEPTCONN, &listening, &size) == 0 && listening) {
        printf("accepting\n");
        fflush(stdout);
        int client = accept(3, NULL, NULL);
        if (client < 0) {
            perror("activation-probe: accept");
            return 1;
        }
        char request[64] = {0};
        ssize_t n = read(client, request, sizeof request - 1);
        if (n <= 0) {
            perror("activation-probe: read");
            return 1;
        }
        request[strcspn(request, "\n")] = 0;
        dprintf(client, "pong %s\n", request);
        close(client);
        printf("served %s\n", request);
    }
    return 0;
}
