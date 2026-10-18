/* Test-only attachment/query helper for ownership and inherited-filter checks. */
#include "../../Sources/LinuxAPI/LinuxAPI.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    int group = open(argv[2], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (group < 0) { perror("open cgroup"); return 1; }
    if (!strcmp(argv[1], "count")) {
        __u32 ids[64] = {0};
        union bpf_attr attr = {0};
        attr.query.target_fd = (__u32)group;
        attr.query.attach_type = BPF_CGROUP_DEVICE;
        attr.query.prog_cnt = 64;
        attr.query.prog_ids = (__u64)(uintptr_t)ids;
        if (syscall(SYS_bpf, BPF_PROG_QUERY, &attr, sizeof(attr))) { perror("query"); return 1; }
        printf("%u\n", attr.query.prog_cnt);
    } else if (!strcmp(argv[1], "detach")) {
        if (argc != 4) return 2;
        int program = linux_bpf_program_open((uint32_t)strtoul(argv[3], NULL, 10));
        if (program < 0 || linux_bpf_device_detach(program, group)) { perror("detach"); return 1; }
        close(program);
    } else {
        struct bpf_insn allow[] = {
            {.code=0xb7, .dst_reg=0, .imm=1}, {.code=0x95},
        };
        struct bpf_insn deny137[] = {
            {.code=0x61, .dst_reg=0, .src_reg=1, .off=4},
            {.code=0x55, .dst_reg=0, .off=5, .imm=137},
            {.code=0x61, .dst_reg=0, .src_reg=1, .off=0},
            {.code=0x77, .dst_reg=0, .imm=16},
            {.code=0x15, .dst_reg=0, .off=2, .imm=1}, /* mknod allowed */
            {.code=0xb7, .dst_reg=0, .imm=0}, {.code=0x95},
            {.code=0xb7, .dst_reg=0, .imm=1}, {.code=0x95},
        };
        const struct bpf_insn *instructions = !strcmp(argv[1], "allow") ? allow : deny137;
        size_t size = !strcmp(argv[1], "allow") ? sizeof(allow) : sizeof(deny137);
        uint8_t log[65536] = {0};
        int program = linux_bpf_device_load((const uint8_t *)instructions, size, log, sizeof(log));
        if (program < 0 || linux_bpf_device_attach(program, group)) {
            perror("load/attach"); fprintf(stderr, "%s\n", log); return 1;
        }
        printf("%u\n", linux_bpf_program_id(program));
        close(program);
    }
    close(group);
    return 0;
}
