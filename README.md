# rv

A local code review tool for the agentic world.

rv shows changes using [Difftastic](https://github.com/Wilfred/difftastic) per file, allows you to add comments, and exports them as a markdown file for the agent to iterate.

## Build

```bash
$ zig build
¢ this is new.
$ zig-out/bin/rv                  # Review working directory changes
$ zig-out/bin/rv --staged         # Review staged changes
$ zig-out/bin/rv -c HEAD~1        # Review specific commit
$ zig-out/bin/rv src/file.zig     # Review specific file
```

## Shortcuts

| Key | Action | 
|-----|--------|
| `↑/↓` | Navigate lines |
| `←/→` | Previous/next file |
| `f/p` | Page forward/backward |
| `g/G` | Go to top/bottom |
| `l` or `.` | Show file list |
| `c` | Add comment |
| `Space` | Select lines |
| `q` | Quit and export |
| `?` | Help |
