# ghostty-mirror.nvim

<img width="200" height="200" alt="ghostty-mirror-icon" src="https://github.com/user-attachments/assets/207c511c-96c7-45de-9451-54b417afe109" />


Mirror Neovim's colorscheme into [Ghostty](https://ghostty.org). When you run
`:colorscheme foo` in Neovim, Ghostty's terminal theme flips to match — across
every open window, instantly.

https://github.com/user-attachments/assets/768f8303-ab48-4e46-9e58-f9e7b1df7386

A `:ThemeFromGhostty` command (bound to `<M-t>` by default) goes the other way:
pulls the theme Ghostty is currently using and applies it locally. Useful for
syncing other Neovim instances running in different tmux panes.


## How it works

A Ghostty theme called `foo` is just a file at
`~/.config/ghostty/themes/foo` that defines `background`, `foreground`, and
the 16-color `palette`. ghostty-mirror's strategy:

1. On `ColorScheme`, it resolves a theme name for the colorscheme (see
   precedence below), writes `theme = <name>` to a small file Ghostty includes
   in its config (`~/.config/ghostty/theme-current` by default).
2. It signals Ghostty (`SIGUSR2`) to reload its config.
3. Ghostty re-reads the include and applies the new theme.

**Resolving the theme name** follows this precedence:

1. A hand-made/cached file at `themes_dir/<name>` (honoring the
   `-light` variant when `&background` is `"light"`) — highest fidelity.
2. Otherwise, **generated on the fly** from Neovim's *live* highlights:
   `background`/`foreground` from `Normal`, `cursor-color` from `Cursor`,
   `selection-background` from `Visual`, and `palette = 0..15` from the
   colorscheme's `g:terminal_color_0..15`. The generated theme is cached to
   `themes_dir/<name>` so you can hand-edit it later. (Set `generate = false`
   to disable.)
3. If a colorscheme doesn't define a full `terminal_color_*` palette,
   generation is skipped silently — the plugin never writes a partial,
   wrong-looking theme.

Most well-maintained colorschemes (catppuccin, tokyonight, kanagawa, gruvbox,
rose-pine, …) set `terminal_color_*`, so generation is zero-config for them.
For ones that don't — or when you want pixel-perfect control — drop a hand-made
file in `themes_dir` (the bundled Claude Code skill can author one for you).

The plugin owns *only* the include file and the themes it generates — it does
not touch your main Ghostty config or your hand-made theme files.

## Installation

### Step 1 — wire Ghostty to read the theme file

Add this to `~/.config/ghostty/config`, and remove any hardcoded
`background`/`foreground`/`palette` lines (they override theme files):

```
config-file = ?~/.config/ghostty/theme-current
```

The `?` makes the include optional, so Ghostty won't error before the file exists.

### Step 2 — install the plugin

`vim.pack`:

```lua
vim.pack.add({ "https://github.com/piacsek/ghostty-mirror.nvim" })
```

`lazy.nvim`:

```lua
{
  "piacsek/ghostty-mirror.nvim",
  event = "VimEnter",
  cmd = { "ThemeFromGhostty", "ThemeToGhostty" },
  keys = { { "<M-t>", desc = "Pull theme from Ghostty" } },
}
```

The plugin auto-registers the `ColorScheme` autocmd, the commands, and the
`<M-t>` keymap with sensible defaults. To override them, call `setup`:

```lua
require("ghostty-mirror").setup({
  themes_dir = "~/.config/ghostty/themes",          -- where themes live / are cached
  theme_file = "~/.config/ghostty/theme-current",   -- the include file the plugin writes
  keymap = "<M-t>",                                 -- false to disable
  user_command = "ThemeFromGhostty",                -- false to disable
  regenerate_command = "ThemeToGhostty",            -- false to disable
  light_variant_suffix = "-light",                  -- light/dark variant routing
  generate = true,                                  -- false to require hand-made files
  reload_command = { "pkill", "-SIGUSR2", "ghostty" },
})
```

### Step 3 — (optional) hand-made theme files

Themes are generated on the fly by default, so you only need this when a
colorscheme doesn't set `g:terminal_color_*` or you want manual control. Drop a
file at `~/.config/ghostty/themes/<colorscheme-name>` — a hand-made file always
wins over generation:

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

## Usage

- `:colorscheme <name>` in Neovim → Ghostty flips to the matching theme
  (hand-made file if present, otherwise generated on the fly).
- `:ThemeFromGhostty` (or `<M-t>`) → pull Ghostty's current theme into this
  Neovim instance. Run this in other nvim windows (across tmux panes, for
  example) to keep them in sync without restarting them.
- `:ThemeToGhostty` → force-regenerate the current colorscheme's theme from
  live highlights, overwriting any cached/hand-made file. Handy after you
  tweak a colorscheme's options and want Ghostty to pick up the new colors.

If you change colorschemes and Ghostty doesn't follow, the colorscheme likely
doesn't expose a `g:terminal_color_*` palette and has no hand-made file at
`~/.config/ghostty/themes/<colorscheme>`. The plugin no-ops silently in that
case — it never writes a theme name Ghostty can't load. Drop a hand-made file
there (the bundled skill can author one).

## Light/dark variants

Some Neovim colorscheme plugins (cyberdream is the canonical example) set the
same `g:colors_name` for both light and dark variants — so the `ColorScheme`
event reports `cyberdream` whether you loaded `cyberdream` or
`cyberdream-light`. To handle this, the plugin checks `&background`: when it's
`"light"` and a `<name><light_variant_suffix>` theme file exists, that's used
instead. Default suffix is `-light`.

So you can ship both `themes/cyberdream` and `themes/cyberdream-light` and
the right one will load automatically.

## Caveats

- **Initial load.** The plugin doesn't fire on Neovim's startup colorscheme;
  opening a new nvim window won't reflow every Ghostty window. If you want the
  startup theme to follow Ghostty (rather than the other way around), read the
  theme yourself in your config:

  ```lua
  local lines = vim.fn.readfile(vim.fn.expand("~/.config/ghostty/theme-current"))
  local theme = lines[1] and lines[1]:match("theme%s*=%s*(%S+)")
  if theme then pcall(vim.cmd.colorscheme, theme) end
  ```

- **`SIGUSR2` reloads all Ghostty windows.** That's how Ghostty's config
  reload works today — there's no per-window override. Switching themes in
  any nvim flips every Ghostty window.

- **Plugin colorschemes load late.** If you call `:colorscheme some-plugin`
  before the plugin is loaded, the colorscheme fails. The autocmd still works
  fine in normal use; this only matters if you set the colorscheme in
  `init.lua` before plugins are loaded — wrap it in `pcall` and retry on
  `VimEnter` if needed.

## Development

The plugin has a plenary-based test suite. With plenary installed via your
plugin manager (or fetched into `~/.local/share/nvim/site/pack/vendor/start/`),
run:

```sh
make test
```

CI runs the same on stable and nightly Neovim.

## License

MIT
