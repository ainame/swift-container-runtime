/* A private loopback listener makes namespace joining observable through I/O. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static void fail(const char *message) { perror(message); exit(1); }
static int socket4(int timed) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) fail("socket");
    struct timeval timeout = {.tv_sec=3};
    if (timed && setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout))) fail("timeout");
    return fd;
}
static void no_inherited_fds(void) {
    DIR *fds = opendir("/proc/self/fd");
    if (!fds) fail("fd directory");
    struct dirent *entry;
    while ((entry = readdir(fds))) {
        char *end;
        long fd = strtol(entry->d_name, &end, 10);
        if (*end == 0 && fd > 2 && fd != dirfd(fds)) fail("inherited namespace descriptor");
    }
    closedir(fds);
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int server = !strcmp(argv[1], "server");
    if (!server && strcmp(argv[1], "outside")) no_inherited_fds();
    int fd = socket4(!server);
    struct sockaddr_in address = {.sin_family=AF_INET, .sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if (server) {
        struct ifreq request = {0};
        strcpy(request.ifr_name, "lo");
        if (ioctl(fd, SIOCGIFFLAGS, &request)) fail("get loopback flags");
        request.ifr_flags |= IFF_UP;
        if (ioctl(fd, SIOCSIFFLAGS, &request)) fail("bring up private loopback");
        if (bind(fd, (struct sockaddr *)&address, sizeof(address)) || listen(fd, 8)) fail("listen");
        socklen_t size = sizeof(address);
        if (getsockname(fd, (struct sockaddr *)&address, &size)) fail("port");
        FILE *port = fopen(argv[2], "w");
        if (!port) fail("port file");
        fprintf(port, "%u\n", ntohs(address.sin_port));
        if (fclose(port)) fail("publish port");
        for (;;) {
            int client = accept4(fd, NULL, NULL, SOCK_CLOEXEC);
            if (client < 0) { if (errno == EINTR) continue; fail("accept"); }
            if (write(client, "joined-network\n", 15) != 15) fail("write reply");
            close(client);
        }
    }
    address.sin_port = htons((unsigned short)strtoul(argv[2], NULL, 10));
    if (!strcmp(argv[1], "outside")) {
        int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
        if (result != -1 || errno != ECONNREFUSED) fail("listener escaped private namespace");
        close(fd);
        return 0;
    }
    if (connect(fd, (struct sockaddr *)&address, sizeof(address))) fail("connect in joined namespace");
    char data[16] = {0};
    size_t used = 0;
    while (used < 15) {
        ssize_t count = read(fd, data + used, 15 - used);
        if (count <= 0) fail("read reply");
        used += (size_t)count;
    }
    close(fd);
    if (strcmp(data, "joined-network\n")) fail("wrong namespace reply");
    puts(data);
    return 0;
}
