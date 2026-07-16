# rv

`rv` is a terminal code-review viewer for structural diffs. It groups changes by declarations, keeps syntax context visible, and supports unified and side-by-side views for Zig, Rust, Go, Python, and TypeScript.

## Requirements

- Zig 0.16.0
- Git, for repository mode
- A terminal with UTF-8 support

## Build and test

```sh
zig build
zig build test --summary all
zig build -Doptimize=ReleaseSafe
```

The executable is written to `zig-out/bin/rv`.

## Usage

Review unstaged changes in the current Git worktree:

```sh
rv
```

Repository mode compares the index with the worktree, matching plain `git diff` semantics. Staged-only and untracked files are not included.

Compare two files directly:

```sh
rv path/to/before.zig path/to/after.zig
```

Both inputs must use a supported extension. Source files are limited to less than 16 MiB each so structural and inline diff algorithms remain bounded. Changed symbolic links are compared by link-target text and are never followed.

## Controls

| Key                      | Action                                                           |
|--------------------------|------------------------------------------------------------------|
| `j`, `k`, arrows         | Move cursor                                                      |
| `PgUp`, `PgDn`           | Move by one viewport                                             |
| `Home`, `End`            | Move to first or last row                                        |
| `Space`, `Enter`         | Expand or collapse the focused declaration or context gap       |
| `[`, `]`                 | Collapse or expand all                                           |
| `v`                      | Toggle unified and split views                                   |
| `n`, `p`                 | Next or previous declaration                                     |
| `N`, `P`                 | Next or previous changed declaration                             |
| `g`, `G`                 | First or last declaration                                        |
| `/`                      | Search the current diff                                          |
| `n`, `N` while searching | Next or previous search match                                    |
| `Esc`                    | Clear search and restore the pre-search fold state               |
| `q`, `Ctrl-C`            | Quit                                                             |

In repository mode, `Tab` switches focus between the file list and diff pane, and search starts when the diff pane has focus. Path mode supports mouse-wheel scrolling and click-to-focus when the terminal reports mouse events.

## Golden fixtures

Golden tests live under `tests/fixtures`. Regenerate expected output intentionally with:

```sh
RV_REGEN=1 zig build test
```

The test suite fails if the fixture root, a fixture input, or all fixture scenarios are missing.
