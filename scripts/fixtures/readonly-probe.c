/* Test-only probe for scripts/readonly-integration.sh. Each argument is one
 * operation, reported as one line with the exact errno name, so a denied
 * write is told apart from EACCES or a missing path:
 *   write:PATH   open an existing file O_WRONLY|O_APPEND and write a byte
 *   create:PATH  create a new file with O_CREAT|O_EXCL
 *   mkdir:PATH   create a new directory
 *   cwd          print the working directory
 *   flags:PATH   print the statvfs mount flags of PATH (ro nosuid nodev noexec)
 *   id           print the real and effective uid
 * Exits 0 once every operation was attempted, 2 on a usage error. */
/* glibc declares ST_NODEV, ST_NOEXEC and the other non-POSIX statvfs flags
 * only under _GNU_SOURCE; musl declares them unconditionally. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

static const char *name(int code) {
    switch (code) {
    case 0: return "ok";
    case EROFS: return "EROFS";
    case EACCES: return "EACCES";
    case EPERM: return "EPERM";
    case ENOENT: return "ENOENT";
    case EEXIST: return "EEXIST";
    case ENOTDIR: return "ENOTDIR";
    case ENOSPC: return "ENOSPC";
    default: return "other";
    }
}

static int write_existing(const char *path) {
    int fd = open(path, O_WRONLY | O_APPEND | O_CLOEXEC);
    if (fd < 0) return errno;
    int code = write(fd, "x", 1) == 1 ? 0 : errno;
    if (close(fd) != 0 && code == 0) code = errno;
    return code;
}

static int create_file(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (fd < 0) return errno;
    return close(fd) == 0 ? 0 : errno;
}

int main(int argc, char **argv) {
    for (int index = 1; index < argc; index++) {
        const char *operation = argv[index];
        const char *colon = strchr(operation, ':');
        const char *path = colon ? colon + 1 : "";
        size_t length = colon ? (size_t)(colon - operation) : strlen(operation);
        if (length == 5 && strncmp(operation, "write", 5) == 0) {
            printf("write %s %s\n", path, name(write_existing(path)));
        } else if (length == 6 && strncmp(operation, "create", 6) == 0) {
            printf("create %s %s\n", path, name(create_file(path)));
        } else if (length == 5 && strncmp(operation, "mkdir", 5) == 0) {
            printf("mkdir %s %s\n", path, name(mkdir(path, 0755) == 0 ? 0 : errno));
        } else if (strcmp(operation, "cwd") == 0) {
            char buffer[4096];
            printf("cwd %s\n", getcwd(buffer, sizeof buffer) ? buffer : name(errno));
        } else if (length == 5 && strncmp(operation, "flags", 5) == 0) {
            struct statvfs status;
            if (statvfs(path, &status) != 0) {
                printf("flags %s %s\n", path, name(errno));
                continue;
            }
            printf("flags %s %s%s%s%s\n", path, (status.f_flag & ST_RDONLY) ? "ro" : "rw",
                   (status.f_flag & ST_NOSUID) ? " nosuid" : "", (status.f_flag & ST_NODEV) ? " nodev" : "",
                   (status.f_flag & ST_NOEXEC) ? " noexec" : "");
        } else if (strcmp(operation, "id") == 0) {
            printf("id %u %u\n", (unsigned)getuid(), (unsigned)geteuid());
        } else {
            fprintf(stderr, "readonly-probe: unknown operation %s\n", operation);
            return 2;
        }
    }
    return fflush(stdout) == 0 ? 0 : 1;
}
