# AGENTS.md - Instructions for AI Agents

## Project Overview

`rv` is a local code review CLI tool written in Zig 0.16.0 that uses semantic diffs (difftastic) with an interactive TUI for commenting.

## Build & Run

```bash
zig build              # Build
zig build run          # Run
zig build test         # Run tests
```

## Key Dependencies

- **libvaxis**: TUI library (in build.zig.zon)
- **difft**: Requires `brew install difftastic`, needs `DFT_UNSTABLE=yes` for JSON output

## Code Style

- Use Zig idioms (defer for cleanup, error unions)
- Accept allocator as parameter in functions
- Keep modules focused and testable
- Use descriptive names
- Don't create temporary files to pass information to a different process - handle without temporary files

## Error Handling

- Check difft is installed before proceeding
- Handle git errors gracefully (not a repo, no changes, etc.)
- Return meaningful error messages
- Validate JSON parsing

## Testing

Add tests to each module:
- Test output parsing with sample data
- Test edge cases: empty files, binary files, new/deleted files
- Use `zig build test` to run

Run with:
```bash
zig build test
```

## Architecture

- `src/main.zig` - Entry point, CLI parsing, orchestration
- `src/git.zig` - Git operations (subprocess calls)
- `src/difft.zig` - Run difft, parse JSON output
- `src/review.zig` - Review state, comments, markdown export
- `src/ui.zig` - TUI implementation
- `src/root.zig` - Public library exports
