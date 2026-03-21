# Copy-on-Write Overlay Filesystem

## Overview

Pecan's overlay filesystem provides each agent with an isolated, writable view of a project directory without granting write access to the host. Reads are transparent (agents see the full project), writes go to a per-session scratch layer, and the difference between the two layers is always available as a first-class changeset.

This design is inspired by Google's srcfs/CitC and Linux's overlayfs, adapted for local macOS use via FUSE-T.

## Motivation

The naive approach — a read-write bind mount — has two problems:

1. **Safety**: agents can corrupt or delete source files with no isolation boundary.
2. **Concurrency**: two agents working on the same file will conflict silently.

The overlay approach solves both: each agent works in their own upper layer, the host project is never written to, and changesets are explicit objects that can be reviewed, approved, merged, or discarded.

## Architecture

```
Host project dir (read-only lower layer)
        │
        ▼
┌─────────────────────┐
│  OverlayFilesystem  │  ← FUSE-T process on host, per session
│  (FUSE server)      │
│                     │
│  lower: /project/   │  read-only view of host project
│  upper: .run/       │  writable scratch per session
│         overlay/    │
│         <sessionID>/│
└─────────────────────┘
        │
        ▼  (FUSE mount on host)
.run/fuse/overlay/<sessionID>/
        │
        ▼  (container bind mount)
/project   ← what the agent sees: merged, writable view
```

## Layer Resolution

Every path is resolved through three stages, in order:

1. **Virtual paths** (`/.pecan/`): synthesized metadata, never on disk.
2. **Upper layer** (`~/.run/overlay/<sessionID>/`): agent's writable scratch.
3. **Lower layer** (project directory): original, read-only source.

### Whiteout Convention

Deletions in the upper layer are represented by sentinel files, following the overlayfs convention:

- File deleted: `.wh.<filename>` created in the same upper directory.
- Directory deleted: `.wh.<dirname>` created in the parent upper directory.
- Directory replaced (opaque): `.wh..opq` created inside the upper directory, causing the lower directory's contents to be hidden entirely.

### readdir Merge

Directory listings union the lower and upper layers:

1. Start with lower directory contents.
2. Add any upper-only entries.
3. Remove entries that have a corresponding `.wh.*` whiteout in upper.
4. Exclude `.wh.*` files themselves from the listing.
5. At root (`/`), include the virtual `.pecan` directory.

## Copy-on-Write Semantics

Files are only copied to the upper layer when first written. The sequence for any write operation:

1. If file exists in lower but **not** in upper: copy lower → upper (preserving content).
2. Create any missing parent directories in upper.
3. Perform the write on the upper copy.

This ensures the lower layer is never touched and the upper layer only contains changed files.

## Virtual `/.pecan/` Directory

A synthetic directory injected at the root of every overlay mount. Contents are generated on demand from the current state of the upper layer.

| Path | Content |
|------|---------|
| `/.pecan/diff` | Unified diff (lower vs upper), one `diff -u` block per changed file |
| `/.pecan/changes` | Newline-delimited `[A\|M\|D] <path>` for each changed file |
| `/.pecan/status` | JSON: `{ session_id, modified, added, deleted, generated_at }` |

### Content Cache

Virtual file content is computed lazily and cached per-path. The cache is invalidated on any write, create, unlink, rename, or truncate operation. This means:

- `getattr` on a virtual file computes (or returns cached) content to report the correct `st_size`.
- `read` serves from the same cache.
- Any mutation to the overlay clears the cache, ensuring the next stat/read reflects current state.

## Changeset Workflow

```
Agent works in /project  →  changes accumulate in upper layer
        │
        ▼
cat /.pecan/diff          →  inspect what changed
cat /.pecan/changes       →  list of touched paths
        │
        ├──► Discard: delete upper layer, start fresh
        │
        ├──► Promote (auto-approve): apply diff to lower layer directly
        │
        └──► Review → Merge: pass diff to reviewer agent or human,
                             apply approved hunks to lower or another
                             agent's upper layer
```

The merge skill handles the review → merge path. It can:
- Apply the full diff (`patch -p0 < /.pecan/diff`)
- Apply selected hunks interactively
- Create a pull request from the diff
- Apply to another session's upper layer (agent-to-agent merge)

## File Operations Summary

| Operation | Behavior |
|-----------|---------|
| `getattr` | Upper → (whiteout → ENOENT) → Lower → virtual |
| `readdir` | Union(lower, upper) minus whiteouts, plus `.pecan` at root |
| `read` | Upper → Lower; virtual paths generate content |
| `write` | COW if needed, write to upper; invalidate cache |
| `create` | Create in upper; invalidate cache |
| `truncate` | COW if needed, truncate upper; invalidate cache |
| `unlink` | Whiteout in upper if in lower; delete if upper-only; invalidate cache |
| `mkdir` | Create in upper |
| `rmdir` | Whiteout in upper if in lower; delete if upper-only |
| `rename` | COW source if needed; copy to dest in upper; whiteout source; invalidate cache |

## Future Work

- **Remote lower layers**: The lower layer abstraction is intentionally simple (a local directory). A future version could make the lower layer a remote content-addressed store (similar to srcfs/CitC), enabling agents to work on large repositories without local checkouts.
- **Content-addressed upper layer**: Store upper layer objects by hash for deduplication across sessions working on similar changes.
- **Partial promotion**: Promote individual files or hunks rather than the whole changeset.
- **Snapshot / checkpoint**: Save named snapshots of the upper layer mid-session so agents can experiment and roll back.
- **Upper layer caching / prefetch**: For remote lower layers, prefetch likely-needed files based on access patterns.
- **Diff streaming**: Stream the diff incrementally rather than computing all at once, for very large changesets.

## Key Files

| File | Role |
|------|------|
| `Sources/PecanFSServer/OverlayFilesystem.swift` | FUSE filesystem implementation |
| `Sources/PecanFSServer/FilesystemProtocol.swift` | `PecanFuseFS` protocol shared by all filesystems |
| `Sources/PecanFSServer/main.swift` | Entry point; `--mode overlay --lower-dir X --upper-dir X` |
| `Sources/PecanServer/FSServerManager.swift` | Per-session overlay mount lifecycle |
| `Sources/PecanServer/main.swift` | Replaces project rw bind mount with overlay mount |
