/* Keyctl directly, with no libkeyutils dependency. Parent mode keeps its own
 * session alive and checks it after the runtime returns. */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/filter.h>
#include <linux/keyctl.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

static void fail(const char *message) { perror(message); exit(1); }
static long session(void) {
    long key = syscall(SYS_keyctl, KEYCTL_GET_KEYRING_ID, KEY_SPEC_SESSION_KEYRING, 0);
    if (key < 0) fail("session ID");
    return key;
}
static void add(const char *name) {
    if (syscall(SYS_add_key, "user", name, "secret", 6, KEY_SPEC_SESSION_KEYRING) < 0) fail("add key");
}
static int present(const char *name) {
    long key = syscall(SYS_keyctl, KEYCTL_SEARCH, KEY_SPEC_SESSION_KEYRING, "user", name, 0);
    if (key < 0 && errno != ENOKEY) fail("search key");
    return key >= 0;
}
static void inspect(void) {
    long key = session();
    char description[4096] = {0};
    long length = syscall(SYS_keyctl, KEYCTL_DESCRIBE, key, description, sizeof(description));
    if (length <= 0 || length > (long)sizeof(description)) fail("describe keyring");
    printf("keyring=%ld\ndescription=%s\nparent-secret=%d\ncontainer-secret=%d\n", key, description, present("sct-parent-secret"), present("sct-container-secret"));
    fflush(stdout);
}
int main(int argc, char **argv) {
    if (argc >= 4 && !strcmp(argv[1], "parent")) {
        long key = syscall(SYS_keyctl, KEYCTL_JOIN_SESSION_KEYRING, NULL);
        if (key < 0) fail("parent session");
        add("sct-parent-secret");
        FILE *file = fopen(argv[2], "w");
        if (!file) fail("parent ID file");
        fprintf(file, "%ld\n", key);
        if (fclose(file)) fail("parent ID close");
        pid_t child = fork();
        if (child < 0) fail("fork runtime");
        if (!child) { execvp(argv[3], argv + 3); fail("exec runtime"); }
        int status;
        while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) fail("wait runtime"); }
        if (session() != key) { fprintf(stderr, "runtime changed caller keyring\n"); return 1; }
        return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    }
    if (argc >= 5 && !strcmp(argv[1], "deny")) {
        int command = !strcmp(argv[2], "permissions") ? KEYCTL_SETPERM : KEYCTL_JOIN_SESSION_KEYRING;
        unsigned int error = !strcmp(argv[3], "ENOSYS") ? ENOSYS : EPERM;
        struct sock_filter code[] = {
            BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
            BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_keyctl, 0, 3),
            BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
            BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, command, 0, 1),
            BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | error),
            BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog program = {.len = sizeof(code) / sizeof(code[0]), .filter = code};
        if (syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &program)) fail("outer filter");
        execvp(argv[4], argv + 4);
        fail("exec denied keyctl runtime");
    }
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "put") || !strcmp(argv[1], "hold")) {
        add("sct-container-secret");
        inspect();
        if (!strcmp(argv[1], "put")) return 0;
        for (;;) pause();
    }
    if (strcmp(argv[1], "inspect")) return 2;
    inspect();
    return 0;
}
