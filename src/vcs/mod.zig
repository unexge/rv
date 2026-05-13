//! VCS abstraction for rv.
//!
//! Everything the binary needs to know about a version-control repository
//! lives behind this module. The diff engine in `src/root.zig` must stay
//! unaware of it; only `main.zig` and the repo-mode UI are allowed to
//! import `vcs/mod.zig`.
//!
//! For now there is a single backend (`git.zig`, subprocess-based). The
//! `Repo` alias is the one-line swap point once a second backend exists
//! (libgit2, jj, ...).

const git = @import("git.zig");

/// High-level classification of a single changed file. The engine only
/// diffs `modified` / `renamed` pairs; every other variant renders a
/// placeholder in the UI.
pub const ChangeKind = enum {
    modified,
    added,
    deleted,
    renamed,
    binary,
    unsupported,
};

/// Added / removed line counts as reported by `git diff --numstat`.
/// Zeroed out for binary or unsupported entries.
pub const LineStat = struct {
    added: u32,
    removed: u32,
};

/// One entry per file reported by `listChanges`.
///
/// - `old_path` is null for pure additions.
/// - `new_path` is null for pure deletions.
/// - Both are set (and differ) for renames; both are set (and equal) for
///   in-place modifications.
///
/// All path slices are owned by the `Repo`'s arena and live until the
/// repo is deinitialised.
pub const FileChange = struct {
    kind: ChangeKind,
    old_path: ?[]const u8,
    new_path: ?[]const u8,
    line_stat: LineStat,
};

pub const Repo = git.GitRepo;

pub const DiscoverError = git.DiscoverError;
pub const ListError = git.ListError;
pub const LoadError = git.LoadError;

comptime {
    _ = @import("git.zig");
}
