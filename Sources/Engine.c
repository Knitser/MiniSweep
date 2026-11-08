#include "Engine.h"
#include <fts.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <stdbool.h>
#include <limits.h>
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
/* Type totals are additive. Aggregate up to 512 raw extensions before crossing
   into Swift, then flush without dropping uncommon or non-ASCII extensions. */
typedef struct { char name[33]; int64_t allocated, logical; uint64_t files; } MSTypeSlot;
typedef struct {
    MSTypeSlot slots[1024];
    size_t count;
    MSScanCallback callback;
    void *context;
} MSTypeBatch;
static void flush_types(MSTypeBatch *batch) {
    for (size_t i = 0; i < 1024; i++) if (batch->slots[i].files) {
        MSTypeSlot *slot = &batch->slots[i];
        batch->callback(batch->context, slot->name, 5, slot->allocated, slot->logical, slot->files, 0);
    }
    memset(batch->slots, 0, sizeof(batch->slots)); batch->count = 0;
}
static void add_type(MSTypeBatch *batch, const char *name, int64_t allocated, int64_t logical) {
    if (batch->count == 512) flush_types(batch);
    uint32_t hash = 2166136261u;
    for (const unsigned char *p = (const unsigned char *)name; *p; p++) hash = (hash ^ *p) * 16777619u;
    size_t index = hash & 1023;
    while (batch->slots[index].files && strcmp(batch->slots[index].name, name)) index = (index + 1) & 1023;
    MSTypeSlot *slot = &batch->slots[index];
    if (!slot->files) { strlcpy(slot->name, name, sizeof(slot->name)); batch->count++; }
    slot->allocated += allocated; slot->logical += logical; slot->files++;
}
static int scan_fts(MSScan *scan, const char *root, int max_depth, MSScanCallback cb, void *ctx, bool optimized) {
    if (atomic_load(&scan->cancelled)) return ECANCELED;
    char *paths[] = {strdup(root), NULL};
    if (!paths[0]) return ENOMEM;
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, NULL);
    if (!tree) { int e = errno; free(paths[0]); return e; }
    FTSENT *e = NULL; MSTotals *pending = NULL; uint64_t files = 0; int64_t seen = 0; double last = 0;
    int result = 0; uint64_t ticks = 0;
    MSTypeBatch types = { .callback = cb, .context = ctx };
    for (;;) {
        if (atomic_load(&scan->cancelled)) { result = ECANCELED; break; }
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
            cb(ctx, e->fts_path, 4, 0, 0, 0, e->fts_info == FTS_DC ? ELOOP : e->fts_errno);
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
                if (optimized) add_type(&types, extension, allocated, logical);
                else cb(ctx, extension, 5, allocated, logical, 1, 0);
            }
            if (e->fts_level <= max_depth || allocated >= 8 * 1024 * 1024)
                cb(ctx, e->fts_path, 2, allocated, logical, 1, S_ISLNK(e->fts_statp->st_mode) ? 1 : 0);
        }
        /* Cancellation remains per-entry, but timing does not need a clock
           syscall for every file. Directory boundaries keep sparse trees live. */
        bool check_time = !optimized || !(++ticks & 127) || e->fts_info == FTS_DP || e->fts_info == FTS_DNR;
        if (check_time) {
            double now = monotonic_time();
            if (now - last >= 0.3) {
                if (optimized) {
                    FTSENT *branch = NULL; int64_t partial = 0, logical = 0; uint64_t count = 0;
                    for (FTSENT *p = e; p && p->fts_level > 0; p = p->fts_parent) {
                        MSTotals *t = (p->fts_info == FTS_D || p->fts_info == FTS_DP || p->fts_info == FTS_DNR) ? p->fts_pointer : NULL;
                        if (t) { partial += t->allocated; logical += t->logical; count += t->files; if (p->fts_level == 1) branch = p; }
                    }
                    if (branch) {
                        /* fts_path is a shared current-entry buffer; the parent
                           path is only its recorded prefix. */
                        char *path = strndup(branch->fts_path, branch->fts_pathlen);
                        if (path) { cb(ctx, path, 6, partial, logical, count, 0); free(path); }
                    }
                }
                cb(ctx, e->fts_path, 3, seen, 0, files, 0); last = now;
            }
        }
    }
    // fts_close does not free user pointers; release outstanding nodes on every exit path.
    while (pending) { MSTotals *next = pending->next; free(pending); pending = next; }
    if (optimized) flush_types(&types);
    fts_close(tree); free(paths[0]); return result;
}

/* getattrlistbulk returns an entire directory's metadata in batches. No file
   contents are opened. Unavailable attributes use fstatat, and filesystems
   without bulk support fall back to readdir/fstatat for that directory. */
typedef struct MSDirectory {
    char *path;
    int depth;
    int64_t allocated, logical;
    uint64_t files;
    struct MSDirectory *parent, *children, *next;
    bool enumerated;
} MSDirectory;
typedef struct {
    MSScan *scan;
    MSScanCallback callback;
    void *context;
    int max_depth;
    dev_t device;
    uint64_t files, ticks;
    int64_t seen;
    double last_progress;
    MSDirectory *current;
    void *buffer;
    MSTypeBatch *types;
} MSBulk;

static char *joined_path(const char *parent, const char *name) {
    size_t n = strlen(parent), m = strlen(name);
    bool slash = n && parent[n - 1] != '/';
    if (n > SIZE_MAX - m - 2) return NULL;
    char *result = malloc(n + m + 2);
    if (result) { memcpy(result, parent, n); if (slash) result[n++] = '/'; memcpy(result + n, name, m + 1); }
    return result;
}
static void bulk_progress(MSBulk *b, const char *path, bool force) {
    if (!force && (++b->ticks & 127)) return;
    double now = monotonic_time();
    if (now - b->last_progress < 0.3) return;
    MSDirectory *branch = NULL;
    int64_t allocated = 0, logical = 0; uint64_t files = 0;
    for (MSDirectory *d = b->current; d && d->depth > 0; d = d->parent) {
        allocated += d->allocated; logical += d->logical; files += d->files;
        if (d->depth == 1) branch = d;
    }
    if (branch) b->callback(b->context, branch->path, 6, allocated, logical, files, 0);
    b->callback(b->context, path, 3, b->seen, 0, b->files, 0);
    b->last_progress = now;
}
static int bulk_entry(MSBulk *b, MSDirectory *parent, const char *name,
                      fsobj_type_t type, dev_t device, int64_t allocated, int64_t logical) {
    int depth = parent->depth + 1;
    if (type == VDIR) {
        MSDirectory *child = calloc(1, sizeof(*child));
        if (!child) return ENOMEM;
        child->path = joined_path(parent->path, name);
        if (!child->path) { free(child); return ENOMEM; }
        child->depth = depth; child->allocated = allocated;
        child->parent = parent; child->next = parent->children; parent->children = child;
        /* Match FTS_XDEV: report the boundary directory, but never descend. */
        if (device != b->device) child->enumerated = true;
        bulk_progress(b, child->path, false);
        return 0;
    }
    parent->allocated += allocated; parent->logical += logical; parent->files++;
    b->files++; b->seen += allocated;
    if (type == VREG) {
        const char *extension = strrchr(name, '.');
        if (!extension || extension == name || strlen(extension) > 33) extension = "";
        else extension++;
        add_type(b->types, extension, allocated, logical);
    }
    char *path = NULL;
    if (depth <= b->max_depth || allocated >= 8 * 1024 * 1024 || !(b->ticks & 127)) {
        path = joined_path(parent->path, name); if (!path) return ENOMEM;
    }
    if (depth <= b->max_depth || allocated >= 8 * 1024 * 1024)
        b->callback(b->context, path, 2, allocated, logical, 1, type == VLNK ? 1 : 0);
    bulk_progress(b, path ? path : parent->path, false);
    free(path); return 0;
}
static void bulk_error(MSBulk *b, const char *parent, const char *name, int error) {
    char *path = name ? joined_path(parent, name) : NULL;
    b->callback(b->context, path ? path : parent, 4, 0, 0, 0, error);
    free(path);
}
static fsobj_type_t vnode_type(mode_t mode) {
    if (S_ISDIR(mode)) return VDIR;
    if (S_ISREG(mode)) return VREG;
    if (S_ISLNK(mode)) return VLNK;
    return VNON;
}
static int stat_entry(MSBulk *b, MSDirectory *parent, int fd, const char *name) {
    struct stat info;
    if (fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0) {
        bulk_error(b, parent->path, name, errno); return 0;
    }
    return bulk_entry(b, parent, name, vnode_type(info.st_mode), info.st_dev,
                       (int64_t)info.st_blocks * 512, info.st_size);
}
static int enumerate_fallback(MSBulk *b, MSDirectory *d, int fd) {
    int copy = dup(fd); if (copy < 0) return errno;
    DIR *stream = fdopendir(copy); if (!stream) { int error = errno; close(copy); return error; }
    int result = 0;
    for (;;) {
        if (atomic_load(&b->scan->cancelled)) { result = ECANCELED; break; }
        errno = 0; struct dirent *item = readdir(stream);
        if (!item) { result = errno; break; }
        if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, "..")) continue;
        result = stat_entry(b, d, fd, item->d_name);
        if (result) break;
    }
    closedir(stream); return result;
}

/* Attribute values have four-byte alignment even when their native type is
   wider. Copy the fixed fields instead of dereferencing an unaligned struct. */
static bool copy_field(const char **cursor, const char *end, void *value, size_t size) {
    if ((size_t)(end - *cursor) < size) return false;
    memcpy(value, *cursor, size); *cursor += size; return true;
}
static int enumerate_bulk(MSBulk *b, MSDirectory *d, int fd) {
    struct attrlist request = { .bitmapcount = ATTR_BIT_MAP_COUNT,
        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE,
        .dirattr = ATTR_DIR_ALLOCSIZE,
        .fileattr = ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH };
    bool started = false;
    for (;;) {
        if (atomic_load(&b->scan->cancelled)) return ECANCELED;
        int count = getattrlistbulk(fd, &request, b->buffer, 256 * 1024, FSOPT_PACK_INVAL_ATTRS);
        if (count < 0) {
            int error = errno;
            if (!started && (error == ENOTSUP || error == EINVAL || error == ENOSYS)) return enumerate_fallback(b, d, fd);
            return error;
        }
        if (!count) return 0;
        started = true;
        const char *record = b->buffer, *limit = record + 256 * 1024;
        for (int i = 0; i < count; i++) {
            if (atomic_load(&b->scan->cancelled)) return ECANCELED;
            uint32_t length, error = 0; attribute_set_t returned = {0}; attrreference_t name_ref;
            dev_t device; fsobj_type_t type; off_t allocated = 0, logical = 0;
            const char *cursor = record;
            if (!copy_field(&cursor, limit, &length, sizeof(length)) || length < 4 || length > (size_t)(limit - record)) return EIO;
            const char *end = record + length;
            if (!copy_field(&cursor, end, &returned, sizeof(returned)) ||
                !copy_field(&cursor, end, &error, sizeof(error))) return EIO;
            const char *name_base = cursor;
            if (!copy_field(&cursor, end, &name_ref, sizeof(name_ref)) ||
                !copy_field(&cursor, end, &device, sizeof(device)) ||
                !copy_field(&cursor, end, &type, sizeof(type))) return EIO;
            /* File attributes are omitted for directories (and vice versa),
               including with FSOPT_PACK_INVAL_ATTRS. */
            if (!error && (!copy_field(&cursor, end, &allocated, sizeof(allocated)) ||
                (type != VDIR && !copy_field(&cursor, end, &logical, sizeof(logical))))) return EIO;
            if (!(returned.commonattr & ATTR_CMN_NAME) || name_ref.attr_dataoffset < 0 ||
                (size_t)name_ref.attr_dataoffset > (size_t)(end - name_base) || !name_ref.attr_length ||
                name_ref.attr_length > (size_t)(end - name_base) - name_ref.attr_dataoffset) return EIO;
            const char *name = name_base + name_ref.attr_dataoffset;
            if (!memchr(name, 0, name_ref.attr_length) || !name[0] || strchr(name, '/') ||
                !strcmp(name, ".") || !strcmp(name, "..")) return EIO;
            if (error) bulk_error(b, d->path, name, error);
            else {
                bool valid = (returned.commonattr & (ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE)) == (ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE) &&
                    (type == VDIR ? (returned.dirattr & ATTR_DIR_ALLOCSIZE) != 0 :
                    (returned.fileattr & (ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH)) == (ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH));
                int result = valid ? bulk_entry(b, d, name, type, device, allocated, logical) : stat_entry(b, d, fd, name);
                if (result) return result;
            }
            record = end;
        }
    }
}
static int scan_bulk(MSScan *scan, const char *root, int max_depth, MSScanCallback cb, void *ctx) {
    if (atomic_load(&scan->cancelled)) return ECANCELED;
    struct stat info;
    if (lstat(root, &info) != 0) { cb(ctx, root, 4, 0, 0, 0, errno); return 0; }
    if (!S_ISDIR(info.st_mode)) {
        int64_t allocated = (int64_t)info.st_blocks * 512;
        if (S_ISREG(info.st_mode)) {
            const char *name = strrchr(root, '/'); name = name ? name + 1 : root;
            const char *ext = strrchr(name, '.'); if (!ext || ext == name || strlen(ext) > 33) ext = ""; else ext++;
            cb(ctx, ext, 5, allocated, info.st_size, 1, 0);
        }
        cb(ctx, root, 2, allocated, info.st_size, 1, S_ISLNK(info.st_mode) ? 1 : 0); return 0;
    }
    MSDirectory *first = calloc(1, sizeof(*first));
    if (!first) return ENOMEM;
    first->path = strdup(root); if (!first->path) { free(first); return ENOMEM; }
    first->allocated = (int64_t)info.st_blocks * 512;
    MSTypeBatch types = { .callback = cb, .context = ctx };
    MSBulk b = { .scan = scan, .callback = cb, .context = ctx, .max_depth = max_depth, .device = info.st_dev, .current = first, .types = &types };
    b.buffer = malloc(256 * 1024); if (!b.buffer) { free(first->path); free(first); return ENOMEM; }
    int result = 0;
    while (b.current) {
        MSDirectory *d = b.current;
        if (atomic_load(&scan->cancelled)) { result = ECANCELED; break; }
        if (!d->enumerated) {
            d->enumerated = true;
            int fd = open(d->path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (fd < 0) bulk_error(&b, d->path, NULL, errno);
            else {
                struct stat opened;
                if (fstat(fd, &opened) != 0) bulk_error(&b, d->path, NULL, errno);
                else if (opened.st_dev == b.device) {
                    /* Include the opened directory's own allocation, as fts does. */
                    d->allocated = (int64_t)opened.st_blocks * 512;
                    int error = enumerate_bulk(&b, d, fd);
                    if (error == ECANCELED || error == ENOMEM) result = error;
                    else if (error) bulk_error(&b, d->path, NULL, error);
                }
                close(fd);
                if (result) break;
            }
        }
        if (d->children) {
            MSDirectory *child = d->children; d->children = child->next; child->next = NULL; b.current = child;
        } else {
            bulk_progress(&b, d->path, true);
            if (d->depth <= max_depth) cb(ctx, d->path, 1, d->allocated, d->logical, d->files, 0);
            MSDirectory *parent = d->parent;
            if (parent) { parent->allocated += d->allocated; parent->logical += d->logical; parent->files += d->files; }
            b.current = parent; free(d->path); free(d);
        }
    }
    /* Flatten pending children into the cleanup stack, including cancellation. */
    while (b.current) {
        MSDirectory *d = b.current;
        if (d->children) { MSDirectory *child = d->children; d->children = child->next; child->next = NULL; b.current = child; }
        else { b.current = d->parent; free(d->path); free(d); }
    }
    flush_types(&types); free(b.buffer); return result;
}
static int begin_metadata_policy(int *original) {
    *original = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD);
    if (*original < 0) return errno;
    if (setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) != 0) return errno;
    return 0;
}
static int end_metadata_policy(int original, int result) {
    int restored = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, original);
    if (restored != 0 && !result) result = errno;
    return result;
}
int ms_path_identity(const char *path, MSFileIdentity *identity) {
    if (!path || !identity) return EINVAL;
    int original, result = begin_metadata_policy(&original);
    if (result) return result;
    struct stat info;
    if (lstat(path, &info) != 0) result = errno;
    else *identity = (MSFileIdentity) { .device = info.st_dev, .inode = info.st_ino, .length = info.st_size,
        .modifiedSeconds = info.st_mtimespec.tv_sec, .modifiedNanoseconds = info.st_mtimespec.tv_nsec, .mode = info.st_mode };
    return end_metadata_policy(original, result);
}
static int with_materialization_policy(MSScan *scan, const char *root, int max_depth, MSScanCallback callback, void *context, int strategy) {
    if (!scan || !root || !callback) return EINVAL;
    int original, result = begin_metadata_policy(&original);
    if (result) return result;
    result = strategy == 2 ? scan_bulk(scan, root, max_depth, callback, context) : scan_fts(scan, root, max_depth, callback, context, strategy == 0);
    return end_metadata_policy(original, result);
}
int ms_scan_run(MSScan *scan, const char *root, int max_depth, MSScanCallback callback, void *context) {
    return with_materialization_policy(scan, root, max_depth, callback, context, 0);
}
int ms_scan_run_reference(MSScan *scan, const char *root, int max_depth, MSScanCallback callback, void *context) {
    return with_materialization_policy(scan, root, max_depth, callback, context, 1);
}
int ms_scan_run_bulk(MSScan *scan, const char *root, int max_depth, MSScanCallback callback, void *context) {
    return with_materialization_policy(scan, root, max_depth, callback, context, 2);
}

static int scan_shallow_fts(MSScan *scan, const char *root, MSScanCallback cb, void *context) {
    if (atomic_load(&scan->cancelled)) return ECANCELED;
    struct stat info;
    if (lstat(root, &info) != 0) return errno;
    if (!S_ISDIR(info.st_mode)) return ENOTDIR;
    char *paths[] = {strdup(root), NULL};
    if (!paths[0]) return ENOMEM;
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, NULL);
    if (!tree) { int error = errno; free(paths[0]); return error; }
    int result = 0; uint64_t files = 0, ticks = 0; int64_t bytes = 0; double last = 0;
    for (;;) {
        if (atomic_load(&scan->cancelled)) { result = ECANCELED; break; }
        errno = 0; FTSENT *entry = fts_read(tree);
        if (!entry) { if (errno) result = errno; break; }
        if (entry->fts_info == FTS_D) {
            if (entry->fts_level == 1) {
                if (fts_set(tree, entry, FTS_SKIP) != 0) { result = errno ? errno : EIO; break; }
                int64_t own = entry->fts_statp ? (int64_t)entry->fts_statp->st_blocks * 512 : 0;
                cb(context, entry->fts_path, 1, own, 0, 0, 0);
            }
        } else if (entry->fts_info == FTS_DNR || entry->fts_info == FTS_ERR ||
                   entry->fts_info == FTS_NS || entry->fts_info == FTS_DC) {
            int error = entry->fts_info == FTS_DC ? ELOOP : entry->fts_errno;
            cb(context, entry->fts_path, 4, 0, 0, 0, error);
        } else if (entry->fts_info != FTS_DP && entry->fts_statp) {
            if (entry->fts_level == 0) { result = ENOTDIR; break; }
            if (entry->fts_level == 1) {
                int64_t allocated = (int64_t)entry->fts_statp->st_blocks * 512;
                cb(context, entry->fts_path, 2, allocated, entry->fts_statp->st_size, 1,
                   S_ISLNK(entry->fts_statp->st_mode) ? 1 : 0);
                bytes += allocated; files++;
            }
        }
        if (!(++ticks & 127) || !last) {
            double now = monotonic_time();
            if (now - last >= 0.3) { cb(context, entry->fts_path, 3, bytes, 0, files, 0); last = now; }
        }
    }
    fts_close(tree); free(paths[0]); return result;
}
int ms_scan_shallow(MSScan *scan, const char *root, MSScanCallback callback, void *context) {
    if (!scan || !root || !callback) return EINVAL;
    int original, result = begin_metadata_policy(&original);
    if (result) return result;
    result = scan_shallow_fts(scan, root, callback, context);
    return end_metadata_policy(original, result);
}

void ms_vm_path_context(const char *path, char *out, size_t capacity, char *storage, size_t storage_capacity) {
    if (!path || !out || !storage || !capacity || !storage_capacity) return;
    if (strstr(path, "/Application Support/Claude/")) {
        strlcpy(out, "Claude", capacity);
        const char *bundle = strstr(path, ".bundle/");
        if (strstr(path, "/vm_bundles/") && bundle) {
            size_t length = (size_t)(bundle - path) + strlen(".bundle");
            if (length < storage_capacity) { memcpy(storage, path, length); storage[length] = 0; }
        }
    } else if (strstr(path, "/com.docker.") || strstr(path, "/group.com.docker/") || strstr(path, "/.docker/")) {
        strlcpy(out, "Docker", capacity);
        const char *extension = strrchr(path, '.');
        if (extension && (!strcmp(extension, ".raw") || !strcmp(extension, ".qcow2") || !strcmp(extension, ".img"))) {
            strlcpy(storage, path, storage_capacity);
            char *slash = strrchr(storage, '/'); if (slash) *slash = 0;
        }
    }
}

static void find_vm_owner(int pid, char *out, size_t capacity, char *storage, size_t storage_capacity) {
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
        ms_vm_path_context(path.pvip.vip_path, out, capacity, storage, storage_capacity);
        if (storage[0]) break;
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
        if (strstr(r->executable, "com.apple.Virtualization.VirtualMachine")) find_vm_owner(pids[i], r->owner, sizeof(r->owner), r->storage, sizeof(r->storage));
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
