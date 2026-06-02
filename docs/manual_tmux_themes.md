### Manual tmux themes

When tmux mirroring is enabled, themes are generated on the fly. For finer
control, drop a hand-made file at `<tmux.themes_dir>/<colorscheme-name>.conf`
(default `~/.config/tmux/themes/<name>.conf`). **Hand-made files always win over
generated ones** — exactly like the Ghostty theme files.

A tmux theme file is a list of `set -g *-style` commands. The plugin sources it
into the running server, so anything valid in `tmux.conf` works here.

Theme file example (`~/.config/tmux/themes/scintilla-amethyst.conf`) — the
purpura look:

```tmux
set -g status-style "bg=#2b1f3e,fg=#ffffff"
set -g window-status-style "bg=#2b1f3e,fg=#ffffff"
set -g window-status-current-style "bg=#d900ff,fg=#0e0024"
set -g pane-active-border-style "fg=#d900ff"
set -g pane-border-style "fg=#bd93f9"
set -g message-style "bg=#2b1f3e,fg=#ffffff"
set -g message-command-style "bg=#2b1f3e,fg=#ffffff"
set -g mode-style "bg=#d900ff,fg=#0e0024"
set -g clock-mode-colour "#d900ff"
```

Two things to keep in mind:

1. Colors apply via `*-style` options, so your `window-status-format` /
   `window-status-current-format` must stay layout-only (e.g. `" #I #W "`) — an
   inline `#[bg=…]` in the format overrides the style.
2. To survive a tmux *server* restart, source the pointer file once at startup,
   after your own theme block:
   ```tmux
   if-shell "test -f ~/.config/tmux/theme-current.conf" \
     "source-file ~/.config/tmux/theme-current.conf"
   ```

For light-mode variants, name the file `<name>-light.conf` (honoring the
configured `light_variant_suffix`); it's preferred when `&background` is
`"light"`.
