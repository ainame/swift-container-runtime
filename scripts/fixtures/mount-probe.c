/* Focused filesystem/IPC probe. Never writes a sysfs attribute. */
#define _GNU_SOURCE
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <linux/magic.h>
#include <mqueue.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/statfs.h>
#include <sys/statvfs.h>
#include <unistd.h>

static void fail(const char *stage) { perror(stage); exit(1); }
static void filesystem(const char *path, long type, unsigned long flags) {
    struct statfs fs;
    struct statvfs mount;
    if (statfs(path, &fs) || statvfs(path, &mount)) fail(path);
    if (fs.f_type != type || (mount.f_flag & flags) != flags) {
        fprintf(stderr, "%s: filesystem or mount flags differ\n", path);
        exit(1);
    }
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    const char *name = argv[2];
    struct mq_attr attributes = { .mq_maxmsg = 1, .mq_msgsize = 8 };
    if (!strcmp(argv[1], "host-create")) {
        mqd_t queue = mq_open(name, O_CREAT | O_EXCL | O_RDWR, 0600, &attributes);
        if (queue == (mqd_t)-1) fail("host mq_open");
        if (mq_close(queue)) fail("host mq_close");
        return 0;
    }
    if (!strcmp(argv[1], "host-remove")) {
        if (mq_unlink(name)) fail("host mq_unlink");
        return 0;
    }
    filesystem("/sys", SYSFS_MAGIC, ST_RDONLY | ST_NOSUID | ST_NODEV | ST_NOEXEC);
    filesystem("/dev/mqueue", 0x19800202, /* mqueue statfs type; not exported by these libc headers */ ST_NOSUID | ST_NODEV | ST_NOEXEC);
    filesystem("/dev/shm", TMPFS_MAGIC, ST_NOSUID | ST_NODEV | ST_NOEXEC);
    filesystem("/readonly", TMPFS_MAGIC, ST_RDONLY);
    /* A fresh sysfs mount must reflect this new network namespace, whose
       sole interface is lo, rather than exposing the host's interfaces. */
    DIR *net = opendir("/sys/class/net");
    if (!net) fail("sysfs network view");
    struct dirent *entry;
    int loopback = 0;
    while ((entry = readdir(net))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (strcmp(entry->d_name, "lo")) { fprintf(stderr, "unexpected interface %s\n", entry->d_name); return 1; }
        loopback++;
    }
    if (closedir(net) || loopback != 1) fail("private sysfs loopback");
    errno = 0;
    int fd = open("/readonly/new", O_CREAT | O_WRONLY, 0600);
    if (fd >= 0 || errno != EROFS) fail("read-only tmpfs write was not EROFS");
    errno = 0;
    fd = open("/sys/kernel/uevent_seqnum", O_WRONLY);
    if (fd >= 0 || errno != EROFS) fail("read-only sysfs open was not EROFS");
    /* The same queue exists in the host IPC namespace; O_EXCL proves this
       mount sees the new IPC namespace instead of the host queue. */
    mqd_t queue = mq_open(name, O_CREAT | O_EXCL | O_RDWR, 0600, &attributes);
    if (queue == (mqd_t)-1) fail("private mq_open");
    if (mq_send(queue, "hello", 5, 0)) fail("mq_send");
    char value[8] = {0};
    if (mq_receive(queue, value, sizeof(value), NULL) != 5 || memcmp(value, "hello", 5)) fail("mq_receive");
    if (mq_close(queue) || mq_unlink(name)) fail("private queue cleanup");
    puts("sysfs-ro-net-private mqueue-private shm-tmpfs readonly-EROFS ok");
    return 0;
}
