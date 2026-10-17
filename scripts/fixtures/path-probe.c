/* Test-only probe for scripts/path-controls-integration.sh. Each argument is
 * one operation, reported as one line with the exact errno name:
 *   read:PATH    read up to 256 bytes; prints the count and escaped content
 *   write:PATH   open an existing file O_WRONLY|O_APPEND and write a byte
 *   create:PATH  create a new file with O_CREAT|O_EXCL
 *   mkdir:PATH   create a new directory
 *   stat:PATH    file type, plus major:minor for a character device
 *   list:PATH    number of directory entries other than . and ..
 *   same:A,B     whether A and B are the same inode on the same device
 *   flags:PATH   statvfs mount flags of PATH (ro nosuid nodev noexec)
 *   id           real and effective uid
 * Exits 0 once every operation was attempted, 2 on a usage error. */
/* glibc declares ST_NODEV, ST_NOEXEC and the other non-POSIX statvfs flags
 * only under _GNU_SOURCE; musl declares them unconditionally. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/sysmacros.h>
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
    case EISDIR: return "EISDIR";
    case ELOOP: return "ELOOP";
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

static void read_file(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        printf("read %s %s\n", path, name(errno));
        return;
    }
    char buffer[256];
    ssize_t count = read(fd, buffer, sizeof buffer);
    int code = count < 0 ? errno : 0;
    close(fd);
    if (code != 0) {
        printf("read %s %s\n", path, name(code));
        return;
    }
    printf("read %s ok %zd:", path, count);
    for (ssize_t index = 0; index < count; index++) {
        unsigned char byte = (unsigned char)buffer[index];
        if (byte == '\n') printf("\\n");
        else if (byte < 0x20 || byte > 0x7e) printf("\\x%02x", byte);
        else putchar(byte);
    }
    putchar('\n');
}

static void stat_file(const char *path) {
    struct stat status;
    if (stat(path, &status) != 0) {
        printf("stat %s %s\n", path, name(errno));
        return;
    }
    switch (status.st_mode & S_IFMT) {
    case S_IFCHR:
        printf("stat %s chr %u:%u\n", path, major(status.st_rdev), minor(status.st_rdev));
        break;
    case S_IFDIR: printf("stat %s dir\n", path); break;
    case S_IFREG: printf("stat %s reg %lld\n", path, (long long)status.st_size); break;
    default: printf("stat %s other\n", path); break;
    }
}

static void list_directory(const char *path) {
    DIR *directory = opendir(path);
    if (!directory) {
        printf("list %s %s\n", path, name(errno));
        return;
    }
    int count = 0;
    struct dirent *entry;
    /* readdir returns NULL both at the end and on error; only errno tells. */
    errno = 0;
    while ((entry = readdir(directory))) {
        if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) count++;
        errno = 0;
    }
    int code = errno;
    if (closedir(directory) != 0 && code == 0) code = errno;
    if (code != 0) printf("list %s %s\n", path, name(code));
    else printf("list %s %d\n", path, count);
}

static void same_file(const char *paths) {
    char first[4096];
    const char *comma = strchr(paths, ',');
    if (!comma || (size_t)(comma - paths) >= sizeof first) {
        printf("same %s usage\n", paths);
        return;
    }
    memcpy(first, paths, (size_t)(comma - paths));
    first[comma - paths] = 0;
    struct stat a, b;
    if (stat(first, &a) != 0 || stat(comma + 1, &b) != 0) {
        printf("same %s %s %s\n", first, comma + 1, name(errno));
        return;
    }
    printf("same %s %s %s\n", first, comma + 1, a.st_dev == b.st_dev && a.st_ino == b.st_ino ? "yes" : "no");
}

int main(int argc, char **argv) {
    for (int index = 1; index < argc; index++) {
        const char *operation = argv[index];
        const char *colon = strchr(operation, ':');
        const char *path = colon ? colon + 1 : "";
        size_t length = colon ? (size_t)(colon - operation) : strlen(operation);
        if (length == 4 && strncmp(operation, "read", 4) == 0) {
            read_file(path);
        } else if (length == 5 && strncmp(operation, "write", 5) == 0) {
            printf("write %s %s\n", path, name(write_existing(path)));
        } else if (length == 6 && strncmp(operation, "create", 6) == 0) {
            printf("create %s %s\n", path, name(create_file(path)));
        } else if (length == 5 && strncmp(operation, "mkdir", 5) == 0) {
            printf("mkdir %s %s\n", path, name(mkdir(path, 0755) == 0 ? 0 : errno));
        } else if (length == 4 && strncmp(operation, "stat", 4) == 0) {
            stat_file(path);
        } else if (length == 4 && strncmp(operation, "list", 4) == 0) {
            list_directory(path);
        } else if (length == 4 && strncmp(operation, "same", 4) == 0) {
            same_file(path);
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
            fprintf(stderr, "path-probe: unknown operation %s\n", operation);
            return 2;
        }
    }
    return fflush(stdout) == 0 ? 0 : 1;
}
