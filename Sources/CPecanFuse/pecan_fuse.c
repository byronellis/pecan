#define FUSE_USE_VERSION 26
#include <fuse/fuse.h>
#include <errno.h>
#include <string.h>
#include "pecan_fuse.h"

// Swift sets these before calling pecan_fuse_main().
PecanGetattrFn  pecan_cb_getattr  = NULL;
PecanReaddirFn  pecan_cb_readdir  = NULL;
PecanReadFn     pecan_cb_read     = NULL;
PecanWriteFn    pecan_cb_write    = NULL;
PecanCreateFn   pecan_cb_create   = NULL;
PecanUnlinkFn   pecan_cb_unlink   = NULL;
PecanTruncateFn pecan_cb_truncate = NULL;
PecanRenameFn   pecan_cb_rename   = NULL;
PecanMkdirFn    pecan_cb_mkdir    = NULL;
PecanRmdirFn    pecan_cb_rmdir    = NULL;
PecanReleaseFn  pecan_cb_release  = NULL;

// --- FUSE operation trampolines ---

static int impl_getattr(const char *path, struct stat *stbuf) {
    memset(stbuf, 0, sizeof(*stbuf));
    if (pecan_cb_getattr) return pecan_cb_getattr(path, stbuf);
    return -ENOENT;
}

static int impl_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                        off_t offset, struct fuse_file_info *fi) {
    if (pecan_cb_readdir) return pecan_cb_readdir(path, buf, (void *)filler, offset);
    return -ENOENT;
}

static int impl_open(const char *path, struct fuse_file_info *fi) {
    // Delegate existence check to getattr; always allow open.
    struct stat st;
    if (pecan_cb_getattr && pecan_cb_getattr(path, &st) == 0) return 0;
    return -ENOENT;
}

static int impl_read(const char *path, char *buf, size_t size, off_t offset,
                     struct fuse_file_info *fi) {
    if (pecan_cb_read) return pecan_cb_read(path, buf, size, offset);
    return -EIO;
}

static int impl_write(const char *path, const char *buf, size_t size, off_t offset,
                      struct fuse_file_info *fi) {
    if (pecan_cb_write) return pecan_cb_write(path, buf, size, offset);
    return -EIO;
}

static int impl_create(const char *path, mode_t mode, struct fuse_file_info *fi) {
    if (pecan_cb_create) return pecan_cb_create(path, mode);
    return -EACCES;
}

static int impl_unlink(const char *path) {
    if (pecan_cb_unlink) return pecan_cb_unlink(path);
    return -EACCES;
}

static int impl_truncate(const char *path, off_t size) {
    if (pecan_cb_truncate) return pecan_cb_truncate(path, size);
    return -EACCES;
}

static int impl_rename(const char *from, const char *to) {
    if (pecan_cb_rename) return pecan_cb_rename(from, to);
    return -EACCES;
}

static int impl_mkdir(const char *path, mode_t mode) {
    if (pecan_cb_mkdir) return pecan_cb_mkdir(path, mode);
    return -EACCES;
}

static int impl_rmdir(const char *path) {
    if (pecan_cb_rmdir) return pecan_cb_rmdir(path);
    return -EACCES;
}

static int impl_release(const char *path, struct fuse_file_info *fi) {
    (void)fi;
    if (pecan_cb_release) return pecan_cb_release(path);
    return 0;
}

static struct fuse_operations pecan_ops = {
    .getattr  = impl_getattr,
    .readdir  = impl_readdir,
    .open     = impl_open,
    .read     = impl_read,
    .write    = impl_write,
    .create   = impl_create,
    .unlink   = impl_unlink,
    .truncate = impl_truncate,
    .rename   = impl_rename,
    .mkdir    = impl_mkdir,
    .rmdir    = impl_rmdir,
    .release  = impl_release,
};

int pecan_fuse_main(int argc, char **argv) {
    return fuse_main(argc, argv, &pecan_ops, NULL);
}

void pecan_fuse_fill(void *filler_fn, void *buf, const char *name) {
    fuse_fill_dir_t filler = (fuse_fill_dir_t)filler_fn;
    filler(buf, name, NULL, 0);
}
