### Manual themes
Themes are generated on the fly by default, but if you'd like finer-grain control over a theme file, drop it at `~/.config/ghostty/themes/<colorscheme-name>`. Hand-made files always win over generated ones


Theme file example:

```
background = #1e1e2e
foreground = #cdd6f4
cursor-color = #f5e0dc
palette = 0=#45475a
palette = 1=#f38ba8
palette = 2=#a6e3a1
palette = 3=#f9e2af
palette = 4=#89b4fa
palette = 5=#f5c2e7
palette = 6=#94e2d5
palette = 7=#bac2de
palette = 8=#585b70
palette = 9=#f38ba8
palette = 10=#a6e3a1
palette = 11=#f9e2af
palette = 12=#89b4fa
palette = 13=#f5c2e7
palette = 14=#94e2d5
palette = 15=#a6adc8
```

To reuse a built-in Ghostty theme (`ghostty +list-themes`), the file is one
line: `theme = <name>`.

> **Tip:** with [Claude Code](https://claude.com/claude-code), this repo's
> `.claude/skills/port-nvim-theme-to-ghostty/` skill writes these files for you
> — add the repo with `--add-dir` and ask "port `<colorscheme>` to ghostty".


