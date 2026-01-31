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
- Use native Zig functions from the standard library to interact with the OS instead of using raw C functions

## Error Handling

- Check difft is installed before proceeding
- Handle git errors gracefully (not a repo, no changes, etc.)
- Return meaningful error messages
- Validate JSON parsing

## Commit Conventions

Use [Conventional Commits](https://www.conventionalcommits.org/) format:

- `feat:` - New features
- `fix:` - Bug fixes
- `test:` - Adding or updating tests
- `chore:` - Maintenance tasks
- `ci:` - CI/CD changes
- `docs:` - Documentation changes
- `refactor:` - Code refactoring

Example: `feat: add support for collapsing test blocks`

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

## Task Management
Use `/dex` to break down complex work, track progress across sessions, and coordinate multi-step implementations.
