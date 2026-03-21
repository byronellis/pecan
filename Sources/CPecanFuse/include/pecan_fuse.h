#pragma once
#include <sys/stat.h>
#include <sys/types.h>
#include <stddef.h>

// Swift-friendly callback types — no fuse.h types leak into this header.
// The filler_fn pointer in PecanReaddirFn is the fuse_fill_dir_t opaque ptr;
// call pecan_fuse_fill() to add entries rather than casting it yourself.

typedef int (*PecanGetattrFn)  (const char *path, struct stat *stbuf);
typedef int (*PecanReaddirFn)  (const char *path, void *buf, void *filler_fn, off_t offset);
typedef int (*PecanReadFn)     (const char *path, char *buf, size_t size, off_t offset);
typedef int (*PecanWriteFn)    (const char *path, const char *buf, size_t size, off_t offset);
typedef int (*PecanCreateFn)   (const char *path, mode_t mode);
typedef int (*PecanUnlinkFn)   (const char *path);
typedef int (*PecanTruncateFn) (const char *path, off_t size);
typedef int (*PecanRenameFn)   (const char *from, const char *to);
typedef int (*PecanMkdirFn)    (const char *path, mode_t mode);
typedef int (*PecanRmdirFn)    (const char *path);

// Set these before calling pecan_fuse_main().
extern PecanGetattrFn  pecan_cb_getattr;
extern PecanReaddirFn  pecan_cb_readdir;
extern PecanReadFn     pecan_cb_read;
extern PecanWriteFn    pecan_cb_write;
extern PecanCreateFn   pecan_cb_create;
extern PecanUnlinkFn   pecan_cb_unlink;
extern PecanTruncateFn pecan_cb_truncate;
extern PecanRenameFn   pecan_cb_rename;
extern PecanMkdirFn    pecan_cb_mkdir;
extern PecanRmdirFn    pecan_cb_rmdir;

// Run the FUSE event loop. Pass argc/argv from main() — first non-option
// argument is the mount point.
int pecan_fuse_main(int argc, char **argv);

// Add a directory entry inside a PecanReaddirFn callback.
// Pass the opaque filler_fn and buf straight through from the callback args.
void pecan_fuse_fill(void *filler_fn, void *buf, const char *name);
