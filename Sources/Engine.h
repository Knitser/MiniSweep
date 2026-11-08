#ifndef MINISWEEP_ENGINE_H
#define MINISWEEP_ENGINE_H
#include <stdint.h>
#include <stddef.h>

typedef struct MSScan MSScan;
typedef struct {
    int32_t device;
    uint64_t inode;
    int64_t length, modifiedSeconds, modifiedNanoseconds;
    uint16_t mode;
} MSFileIdentity;
// lstat metadata without allowing cloud-file materialization. Returns errno or 0.
int ms_path_identity(const char *path, MSFileIdentity *identity);
typedef void (*MSScanCallback)(void *context, const char *path, int kind,
                              int64_t allocated, int64_t logical, uint64_t files, int error);
MSScan *ms_scan_create(void);
void ms_scan_cancel(MSScan *scan);
void ms_scan_destroy(MSScan *scan);
// Kinds: 1 finalized directory, 2 file, 3 global progress, 4 unreadable path,
// 5 regular-file extension total, 6 provisional immediate-child directory total.
int ms_scan_run(MSScan *scan, const char *root, int max_depth, MSScanCallback callback, void *context);
// Reference implementation for correctness checks and repeatable benchmarks.
int ms_scan_run_reference(MSScan *scan, const char *root, int max_depth, MSScanCallback callback, void *context);
// Optional bulk metadata path, retained for filesystem-specific benchmarks.
int ms_scan_run_bulk(MSScan *scan, const char *root, int max_depth, MSScanCallback callback, void *context);
// Read immediate children only. Directory kind 1 values are own allocation,
// with logical/files zero; callers must supply cached recursive totals.
// Root and extension totals are omitted. Never follows a root symlink.
int ms_scan_shallow(MSScan *scan, const char *root, MSScanCallback callback, void *context);

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
