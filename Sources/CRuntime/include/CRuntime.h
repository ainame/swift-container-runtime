#ifndef SWIFT_CONTAINER_RUNTIME_H
#define SWIFT_CONTAINER_RUNTIME_H
#include <stddef.h>
#include <stdint.h>

/* All post-fork execution stays in C until exec. No Swift callbacks. */
typedef struct {
    int32_t stage;
    int32_t error_number;
} scr_failure;

/* Returns 0 with workload shell-style status, or -1 with a launch failure. */
int scr_namespace_run(const char *hostname, char *const argv[],
                      int32_t *exit_status, scr_failure *failure);
const char *scr_error_message(int32_t error_number);
const char *scr_stage_name(int32_t stage);
void scr_write_error(const char *message);
#endif
