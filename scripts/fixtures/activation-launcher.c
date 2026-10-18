/* Test fixture for scripts/socket-activation-integration.sh, run on the host.
 *
 *   activation-launcher listen PATH FDS PID COMMAND [ARG...]
 * binds a listening Unix socket at PATH as inheritable descriptor 3, sets
 * LISTEN_FDNAMES=host-name, LISTEN_FDS=FDS, and LISTEN_PID (PID "self" is
 * this process's own PID, " self" the same with a leading space, "other" a
 * different one; "-" leaves a variable unset), then executes COMMAND in this same process, as systemd hands
 * sockets to a service. Nothing may fork between this and COMMAND.
 *
 *   activation-launcher connect PATH REQUEST
 * connects to PATH, sends REQUEST, and prints the reply line. Each wait is
 * bounded to 20 seconds. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

static int address(const char *path, struct sockaddr_un *out) {
    memset(out, 0, sizeof *out);
    out->sun_family = AF_UNIX;
    if (strlen(path) >= sizeof out->sun_path) {
        fprintf(stderr, "activation-launcher: socket path too long\n");
        return -1;
    }
    strcpy(out->sun_path, path);
    return 0;
}

static int set(const char *name, const char *value) {
    if (strcmp(value, "-") == 0) return unsetenv(name);
    return setenv(name, value, 1);
}

static int launch(int argc, char **argv) {
    if (argc < 6) return 2;
    struct sockaddr_un sun;
    if (address(argv[2], &sun) != 0) return 125;
    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0 || bind(sock, (struct sockaddr *)&sun, sizeof sun) != 0 || listen(sock, 4) != 0) {
        perror("activation-launcher: listen");
        return 125;
    }
    if (sock != 3) {
        if (dup2(sock, 3) != 3) {
            perror("activation-launcher: dup2");
            return 125;
        }
        close(sock);
    }
    char pid[32];
    if (strcmp(argv[4], "self") == 0) snprintf(pid, sizeof pid, "%d", (int)getpid());
    else if (strcmp(argv[4], " self") == 0) snprintf(pid, sizeof pid, " %d", (int)getpid());
    else if (strcmp(argv[4], "other") == 0) snprintf(pid, sizeof pid, "%d", (int)getpid() + 1);
    else snprintf(pid, sizeof pid, "%s", argv[4]);
    if (setenv("LISTEN_FDNAMES", "host-name", 1) != 0 || set("LISTEN_FDS", argv[3]) != 0
        || set("LISTEN_PID", pid) != 0) {
        perror("activation-launcher: setenv");
        return 125;
    }
    execv(argv[5], argv + 5);
    perror(argv[5]);
    return 127;
}

static int request(int argc, char **argv) {
    if (argc != 4) return 2;
    struct sockaddr_un sun;
    if (address(argv[2], &sun) != 0) return 1;
    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    struct timeval limit = {20, 0};
    if (sock < 0 || setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof limit) != 0
        || setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &limit, sizeof limit) != 0) {
        perror("activation-launcher: socket");
        return 1;
    }
    if (connect(sock, (struct sockaddr *)&sun, sizeof sun) != 0) {
        perror("activation-launcher: connect");
        return 1;
    }
    dprintf(sock, "%s\n", argv[3]);
    char reply[128] = {0};
    size_t used = 0;
    while (used < sizeof reply - 1 && !memchr(reply, '\n', used)) {
        ssize_t n = read(sock, reply + used, sizeof reply - 1 - used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            fprintf(stderr, "activation-launcher: no reply\n");
            return 1;
        }
        used += (size_t)n;
    }
    fputs(reply, stdout);
    return 0;
}

int main(int argc, char **argv) {
    int status = 2;
    if (argc > 1 && strcmp(argv[1], "listen") == 0) status = launch(argc, argv);
    else if (argc > 1 && strcmp(argv[1], "connect") == 0) status = request(argc, argv);
    if (status == 2) fprintf(stderr, "usage: activation-launcher listen PATH FDS PID COMMAND... | connect PATH REQUEST\n");
    return status;
}
