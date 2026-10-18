/* Bind behavior is checked through actual I/O, execute and device permissions. */
#define _GNU_SOURCE
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/statvfs.h>
#include <sys/wait.h>
#include <unistd.h>

static void fail(const char *message) { perror(message); exit(1); }
static void content(const char *path, const char *expected) {
    char bytes[128] = {0};
    int fd = open(path, O_RDONLY);
    if (fd < 0) fail(path);
    ssize_t length = read(fd, bytes, sizeof(bytes) - 1);
    close(fd);
    if (length < 0 || strcmp(bytes, expected)) fail(path);
}
static void write_file(const char *path, const char *value) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0 || write(fd, value, strlen(value)) != (ssize_t)strlen(value)) fail(path);
    close(fd);
}
static void flags(const char *path, unsigned long required, unsigned long forbidden) {
    struct statvfs value;
    if (statvfs(path, &value) || (value.f_flag & required) != required || (value.f_flag & forbidden)) fail(path);
}
static void execute(const char *path, int denied) {
    pid_t child = fork();
    if (child < 0) fail("fork");
    if (child == 0) {
        char *const args[] = {(char *)path, NULL};
        execv(path, args);
        _exit(denied && errno == EACCES ? 0 : 1);
    }
    int status;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) fail("execute result");
}
int main(void) {
    DIR *fds = opendir("/proc/self/fd");
    if (!fds) fail("open descriptors");
    struct dirent *entry;
    while ((entry = readdir(fds))) {
        char *end;
        long fd = strtol(entry->d_name, &end, 10);
        if (*end == 0 && fd > 2 && fd != dirfd(fds)) fail("unexpected inherited source descriptor");
    }
    closedir(fds);
    content("/new/etc/resolv.conf", "readonly\n");
    content("/etc-link/hosts", "readonly\n");
    content("/absolute-link", "readonly\n");
    content("/escape-link", "readonly\n");
    content("/relative", "relative\n");
    content("/pinned", "before-dev\n");
    content("/recursive/sub/nested", "nested\n");
    errno = 0;
    if (access("/plain/sub/nested", F_OK) == 0 || errno != ENOENT) fail("bind unexpectedly included submount");
    flags("/new/etc/resolv.conf", ST_RDONLY | ST_NOSUID | ST_NODEV | ST_NOEXEC, 0);
    flags("/strict", 0, ST_RELATIME | ST_NOATIME);
    flags("/recursive", ST_RDONLY, 0);
    flags("/recursive/sub", 0, ST_RDONLY);
    flags("/exec-enabled", 0, ST_NOEXEC);
    flags("/device-allowed", 0, ST_NODEV);
    errno = 0;
    int fd = open("/new/etc/resolv.conf", O_WRONLY);
    if (fd >= 0 || errno != EROFS) fail("read-only file must give EROFS");
    errno = 0;
    fd = open("/recursive/new", O_WRONLY | O_CREAT, 0600);
    if (fd >= 0 || errno != EROFS) fail("read-only recursive root must give EROFS");
    write_file("/writable", "container-write\n");
    write_file("/plain/created", "volume-write\n");
    /* rbind,ro intentionally affects only the top mount, like runc. */
    write_file("/recursive/sub/changed", "submount-write\n");
    execute("/exec-blocked", 1);
    execute("/exec-enabled", 0);
    errno = 0;
    fd = open("/device-blocked", O_RDWR);
    if (fd >= 0 || errno != EACCES) fail("nodev device must be denied");
    fd = open("/device-allowed", O_RDWR);
    if (fd < 0 || write(fd, "x", 1) != 1) fail("explicit dev flag");
    close(fd);
    puts("bind files/dirs recursive flags symlinks and I/O ok");
    return 0;
}
