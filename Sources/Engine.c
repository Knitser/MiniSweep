#include "Engine.h"
#include <fts.h>
#include <libproc.h>
#include <mach/mach.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <sys/proc_info.h>
#include <time.h>
#include <unistd.h>

struct MSScan { atomic_int cancelled; };
typedef struct MSTotals { int64_t allocated, logical; uint64_t files; struct MSTotals *prev, *next; } MSTotals;
MSScan *ms_scan_create(void) { return calloc(1, sizeof(MSScan)); }
void ms_scan_cancel(MSScan *s) { if (s) atomic_store(&s->cancelled, 1); }
void ms_scan_destroy(MSScan *s) { free(s); }
static double monotonic_time(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}
int ms_scan_run(MSScan *scan, const char *root, int max_depth, MSScanCallback cb, void *ctx) {
    char *paths[] = {strdup(root), NULL};
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, NULL);
    if (!tree) { int e = errno; free(paths[0]); return e; }
    FTSENT *e = NULL; MSTotals *pending = NULL; uint64_t files = 0; int64_t seen = 0; double last = 0;
    int result = 0;
    for (;;) {
        errno = 0; e = fts_read(tree);
        if (!e) { if (errno) result = errno; break; }
        if (atomic_load(&scan->cancelled)) { result = ECANCELED; break; }
        if (e->fts_info == FTS_D) {
            MSTotals *t = calloc(1, sizeof(MSTotals));
            if (!t) { result = ENOMEM; break; }
            t->next = pending; if (pending) pending->prev = t; pending = t;
            t->allocated = e->fts_statp ? (int64_t)e->fts_statp->st_blocks * 512 : 0;
            e->fts_pointer = t;
        } else if (e->fts_info == FTS_DP || e->fts_info == FTS_DNR) {
            MSTotals *t = e->fts_pointer;
            MSTotals empty = {0}; if (!t) t = &empty;
            if (e->fts_info == FTS_DNR) cb(ctx, e->fts_path, 4, 0, 0, 0, e->fts_errno);
            if (e->fts_level <= max_depth) cb(ctx, e->fts_path, 1, t->allocated, t->logical, t->files, 0);
            if (e->fts_level > 0 && e->fts_parent->fts_pointer) {
                MSTotals *parent = e->fts_parent->fts_pointer;
                parent->allocated += t->allocated; parent->logical += t->logical; parent->files += t->files;
            }
            if (e->fts_pointer) {
                if (t->prev) t->prev->next = t->next; else pending = t->next;
                if (t->next) t->next->prev = t->prev;
                free(t);
            }
            e->fts_pointer = NULL;
        } else if (e->fts_info == FTS_ERR || e->fts_info == FTS_NS || e->fts_info == FTS_DC) {
            cb(ctx, e->fts_path, 4, 0, 0, 0, e->fts_errno ? e->fts_errno : ELOOP);
        } else if (e->fts_statp) {
            int64_t allocated = (int64_t)e->fts_statp->st_blocks * 512;
            int64_t logical = e->fts_statp->st_size;
            MSTotals *parent = e->fts_parent->fts_pointer;
            if (parent) { parent->allocated += allocated; parent->logical += logical; parent->files++; }
            files++; seen += allocated;
            if (S_ISREG(e->fts_statp->st_mode)) {
                const char *extension = strrchr(e->fts_name, '.');
                if (!extension || extension == e->fts_name || strlen(extension) > 33) extension = "";
                else extension++;
                cb(ctx, extension, 5, allocated, logical, 1, 0);
            }
            if (e->fts_level <= max_depth || allocated >= 8 * 1024 * 1024)
                cb(ctx, e->fts_path, 2, allocated, logical, 1, S_ISLNK(e->fts_statp->st_mode) ? 1 : 0);
        }
        double now = monotonic_time();
        if (now - last >= 0.3) { cb(ctx, e->fts_path, 3, seen, 0, files, 0); last = now; }
    }
    // fts_close does not free user pointers; release outstanding nodes on every exit path.
    while (pending) { MSTotals *next = pending->next; free(pending); pending = next; }
    fts_close(tree); free(paths[0]); return result;
}

static void find_vm_owner(int pid, char *out, size_t capacity) {
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0 || bytes > 4 * 1024 * 1024) return;
    struct proc_fdinfo *fds = malloc(bytes);
    if (!fds) return;
    int actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
    if (actual <= 0 || actual > bytes) { free(fds); return; }
    int count = actual / sizeof(*fds);
    for (int i = 0; i < count; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_VNODE) continue;
        struct vnode_fdinfowithpath path = {0};
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &path, sizeof(path)) <= 0) continue;
        if (strstr(path.pvip.vip_path, "/Application Support/Claude/")) { strlcpy(out, "Claude", capacity); break; }
        if (strstr(path.pvip.vip_path, "/com.docker.") || strstr(path.pvip.vip_path, "/.docker/")) {
            strlcpy(out, "Docker", capacity); break;
        }
    }
    free(fds);
}
int ms_processes(MSProcess **output) {
    *output = NULL;
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0) return 0;
    bytes = bytes * 2 + 4096;
    pid_t *pids = calloc(1, bytes);
    if (!pids) return 0;
    int actual = proc_listpids(PROC_ALL_PIDS, 0, pids, bytes);
    if (actual <= 0 || actual > bytes) { free(pids); return 0; }
    int count = actual / sizeof(pid_t);
    MSProcess *rows = calloc(count, sizeof(MSProcess)); int used = 0;
    if (!rows) { free(pids); return 0; }
    for (int i = 0; i < count; i++) {
        if (pids[i] <= 0) continue;
        struct rusage_info_v4 usage = {0};
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) continue;
        if (!usage.ri_phys_footprint) continue;
        MSProcess *r = &rows[used++]; r->pid = pids[i];
        r->footprint = usage.ri_phys_footprint; r->resident = usage.ri_resident_size;
        r->started = usage.ri_proc_start_abstime;
        struct proc_bsdinfo bsd = {0};
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) > 0) r->parent = bsd.pbi_ppid;
        proc_name(pids[i], r->name, sizeof(r->name));
        proc_pidpath(pids[i], r->executable, sizeof(r->executable));
        if (strstr(r->executable, "com.apple.Virtualization.VirtualMachine")) find_vm_owner(pids[i], r->owner, sizeof(r->owner));
    }
    free(pids); *output = rows; return used;
}
void ms_processes_free(MSProcess *p) { free(p); }
MSMemory ms_memory(void) {
    MSMemory out = {0}; size_t size = sizeof(out.physical);
    out.memory_valid = sysctlbyname("hw.memsize", &out.physical, &size, NULL, 0) == 0;
    struct xsw_usage swap = {0}; size = sizeof(swap);
    out.swap_valid = sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0;
    out.swap_used = swap.xsu_used; out.swap_total = swap.xsu_total;
    vm_statistics64_data_t vm = {0}; mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
    vm_size_t page = 0; host_page_size(mach_host_self(), &page);
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &n) == KERN_SUCCESS)
        out.compressed = (uint64_t)vm.compressor_page_count * page;
    return out;
}
