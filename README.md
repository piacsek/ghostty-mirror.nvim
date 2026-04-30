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

1. On `ColorScheme`, it writes `theme = <name>` to a small file Ghostty
   includes in its config (`~/.config/ghostty/theme-current` by default).
2. It signals Ghostty (`SIGUSR2`) to reload its config.
3. Ghostty re-reads the include and applies the new theme.

The plugin owns *only* the include file — it does not touch your main Ghostty
config or your theme files.

## Installation

### Step 1 — wire Ghostty to read the theme file

Add this line to your `~/.config/ghostty/config` **before** any
`background`/`foreground`/`palette` settings (or remove those settings
entirely so themes can drive them):

```
config-file = ?~/.config/ghostty/theme-current
```

The `?` prefix makes the include optional, so Ghostty won't error before the
file exists.

> **Important:** any hardcoded `background`, `foreground`, or `palette = N=...`
> lines in your main config will override theme files. Move those into theme
> files instead, or delete them.

### Step 2 — provide theme files

For each Neovim colorscheme you want mirrored, put a matching theme file at
`~/.config/ghostty/themes/<colorscheme-name>` (no extension).

> **Tip:** if you use [Claude Code](https://claude.com/claude-code), this
> repo ships a skill at `.claude/skills/port-nvim-theme-to-ghostty/` that
> walks an agent through extracting palettes from any Neovim colorscheme
> (bundled, plugin, or shipped Ghostty extras) and writing the right theme
> file. Add this repo with `--add-dir` (or symlink the skill into your
> `~/.claude/skills/`) and ask "port `<colorscheme>` to ghostty" — it'll
> handle the lookup and the file write for you.

Format:

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

Ghostty ships with a long list of built-in themes — `ghostty +list-themes`
shows them. To use an existing one, the file is one line: `theme = <name>`.

### Step 3 — install the plugin

With `vim.pack`:

```lua
vim.pack.add({ "https://github.com/piacsek/ghostty-mirror.nvim" })
```

With `lazy.nvim`:

```lua
{
  "piacsek/ghostty-mirror.nvim",
  event = "VimEnter",                     -- register the ColorScheme autocmd before any user :colorscheme call
  cmd = "ThemeFromGhostty",               -- but also load on the user command
  keys = { { "<M-t>", desc = "Pull theme from Ghostty" } },
}
```

`lazy = false` works too (and is simplest), but the spec above keeps startup
fast while still loading the plugin before you'd realistically change a
colorscheme. The plugin auto-registers a `ColorScheme` autocmd, the
`:ThemeFromGhostty` command, and the `<M-t>` keymap with sensible defaults.

If you want to customize anything, call `setup` explicitly:

```lua
require("ghostty-mirror").setup({
  themes_dir = "~/.config/ghostty/themes",          -- where Ghostty looks for themes
  theme_file = "~/.config/ghostty/theme-current",   -- the include file the plugin writes to
  keymap = "<M-t>",                                 -- false to disable
  user_command = "ThemeFromGhostty",                -- false to disable
  light_variant_suffix = "-light",                  -- routing for plugins that ship light/dark variants
  reload_command = { "pkill", "-SIGUSR2", "ghostty" },
})
```

## Usage

- `:colorscheme <name>` in Neovim → Ghostty flips to the matching theme.
- `:ThemeFromGhostty` (or `<M-t>`) → pull Ghostty's current theme into this
  Neovim instance. Run this in other nvim windows (across tmux panes, for
  example) to keep them in sync without restarting them.

If you change colorschemes and Ghostty doesn't follow, the theme file
probably doesn't exist yet at `~/.config/ghostty/themes/<colorscheme>`. The
plugin no-ops silently in that case — it never writes a theme name Ghostty
can't load.

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
