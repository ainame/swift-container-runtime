/* Test fixture for scripts/preserve-fds-integration.sh, linked statically.
 * Prints every open descriptor except its own /proc/self/fd directory
 * stream, then the first line of stdin and of descriptors 3 and 4 when
 * open, writes a marker to descriptor 5 when open, and writes a marker to
 * stderr. Output: "fds 0 1 2 ...", "stdin TEXT", "fd3 TEXT", "fd4 TEXT". */
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int compare(const void *a, const void *b) {
    return *(const int *)a - *(const int *)b;
}

static void print_line(const char *label, int descriptor) {
    char buffer[128];
    ssize_t count = read(descriptor, buffer, sizeof buffer - 1);
    if (count < 0) {
        printf("%s read-error\n", label);
        return;
    }
    buffer[count] = 0;
    buffer[strcspn(buffer, "\n")] = 0;
    printf("%s %s\n", label, buffer);
}

int main(void) {
    int descriptors[4096];
    size_t count = 0;
    DIR *directory = opendir("/proc/self/fd");
    if (directory == NULL) {
        perror("fd-probe: /proc/self/fd");
        return 2;
    }
    int own = dirfd(directory);
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        int descriptor = atoi(entry->d_name);
        if (descriptor == own) continue;
        if (count == sizeof descriptors / sizeof descriptors[0]) {
            fprintf(stderr, "fd-probe: too many descriptors\n");
            return 2;
        }
        descriptors[count++] = descriptor;
    }
    closedir(directory);
    qsort(descriptors, count, sizeof descriptors[0], compare);
    printf("fds");
    for (size_t i = 0; i < count; i++) printf(" %d", descriptors[i]);
    printf("\n");
    print_line("stdin", 0);
    if (fcntl(3, F_GETFD) >= 0) print_line("fd3", 3);
    if (fcntl(4, F_GETFD) >= 0) print_line("fd4", 4);
    if (fcntl(5, F_GETFD) >= 0) {
        static const char marker[] = "fd5 written\n";
        if (write(5, marker, sizeof marker - 1) != (ssize_t)(sizeof marker - 1)) {
            perror("fd-probe: write fd 5");
            return 2;
        }
    }
    fprintf(stderr, "fd-probe stderr\n");
    return fflush(stdout) == 0 ? 0 : 2;
}
