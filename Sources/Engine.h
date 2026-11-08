#ifndef MINISWEEP_ENGINE_H
#define MINISWEEP_ENGINE_H
#include <stdint.h>
#include <stddef.h>

typedef struct MSScan MSScan;
typedef void (*MSScanCallback)(void *context, const char *path, int kind,
                              int64_t allocated, int64_t logical, uint64_t files, int error);
MSScan *ms_scan_create(void);
void ms_scan_cancel(MSScan *scan);
void ms_scan_destroy(MSScan *scan);
int ms_scan_run(MSScan *scan, const char *root, int max_depth, MSScanCallback callback, void *context);

typedef struct {
    int32_t pid, parent;
    uint64_t footprint, resident, started;
    char name[256];
    char executable[4096];
    char owner[64];
    char storage[4096];
} MSProcess;
int ms_processes(MSProcess **output);
void ms_processes_free(MSProcess *output);
void ms_vm_path_context(const char *path, char *owner, size_t owner_capacity, char *storage, size_t storage_capacity);
typedef struct {
    uint64_t physical, compressed, swap_used, swap_total;
    int memory_valid, swap_valid;
} MSMemory;
MSMemory ms_memory(void);
#endif
