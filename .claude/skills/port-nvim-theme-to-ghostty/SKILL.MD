---
name: port-nvim-theme-to-ghostty
description: Port a Neovim colorscheme to a matching Ghostty theme so ghostty-mirror.nvim can flip Ghostty when the colorscheme changes. Use when the user installs a new nvim colorscheme and wants Ghostty to follow, or asks "add X to ghostty themes", "port X to ghostty", or `:colorscheme X` produces a mismatch with the terminal.
---

# Port a Neovim colorscheme to Ghostty

ghostty-mirror.nvim flips Ghostty's theme when Neovim's colorscheme changes,
but it relies on a matching theme file existing at
`~/.config/ghostty/themes/<colorscheme-name>` (the path is configurable via
the plugin's `themes_dir` option). If the file is missing, the plugin
silently no-ops and Ghostty stays on whatever theme it had. This skill
walks through creating that file from a Neovim colorscheme's source.

## Steps

1. **Find the colorscheme's palette source**, in priority order:
   - **Plugin-shipped Ghostty extras** (best). Some plugins ship a Ghostty
     config under `extras/ghostty/`. Examples:
     ```
     ~/.local/share/nvim/lazy/<plugin>/extras/ghostty/<name>
     ~/.local/share/nvim/site/pack/*/opt/<plugin>/extras/ghostty/<name>
     ```
     If present, copy it directly into the themes directory.
   - **Bundled vim colorschemes**: `$VIMRUNTIME/colors/<name>.vim` (on macOS
     with Homebrew Neovim, that's
     `/opt/homebrew/Cellar/neovim/*/share/nvim/runtime/colors/<name>.vim`).
     Grep for `g:terminal_ansi_colors` (the 16-color palette as a Vim list)
     and `^hi Normal ` (gives `guibg`/`guifg` for background/foreground).
   - **Plugin colorschemes**: hunt under the plugin's install directory.
     Look for `colors/<name>.lua`, `lua/<plugin>/colors.lua`,
     `lua/<plugin>/palette.lua`, `lua/<plugin>/palettes/<flavor>.lua`. Each
     plugin organizes this differently — read until you find the bg/fg and
     16 ANSI colors.

2. **Write the Ghostty theme file** at `<themes_dir>/<name>` (no extension):

   ```
   background = #RRGGBB
   foreground = #RRGGBB
   cursor-color = #RRGGBB

   palette = 0=#RRGGBB
   palette = 1=#RRGGBB
   ...
   palette = 15=#RRGGBB
   ```

   Mapping rules:
   - `background` ← `hi Normal guibg`
   - `foreground` ← `hi Normal guifg`
   - `cursor-color` ← usually `guifg`; for unique cursors check `hi Cursor guibg`
   - `palette = 0..15` ← the 16 entries of `g:terminal_ansi_colors` in order.
     Convention: 0=black, 1=red, 2=green, 3=yellow, 4=blue, 5=magenta,
     6=cyan, 7=white, 8-15 = bright variants.
   - For plugin schemes that don't define ANSI colors explicitly, derive from
     the plugin's palette names (red, green, blue, yellow, cyan, magenta,
     fg, bg). Brights (8-15) can repeat the dim values when the plugin
     doesn't differentiate.

3. **Test**: in Neovim, run `:colorscheme <name>`. The plugin writes
   `theme = <name>` to the theme-current file and signals Ghostty to reload.
   Ghostty should flip immediately. If it doesn't, look for hardcoded
   `background`/`foreground`/`palette` lines in the main Ghostty config that
   override theme files — those must not exist below the
   `config-file = ?...theme-current` include.

## Light/dark variants of the same plugin

Some plugins (cyberdream is the canonical example) set the same
`g:colors_name` for both light and dark variants. The plugin handles this
automatically: when `&background == "light"` and a `<name>-light` theme file
exists, it prefers that (the suffix is configurable via
`light_variant_suffix`). So if a plugin ships separate variants, name the
files `<name>` and `<name>-light` and routing happens for free.

## Common gotchas

- **Don't put `background`/`foreground`/`palette` lines in the main Ghostty
  config below the `config-file = ?...` include**. They'll override anything
  theme files set. Keep those settings in theme files only.
- **Plugins behind a lazy loader aren't loaded yet during early `init.lua`**.
  If you `:colorscheme <plugin-theme>` before the plugin loads (e.g. in
  `options.lua`), the colorscheme call fails. Wrap in `pcall` and retry on
  `VimEnter` if you need it to work that early.
- **Bundled `colors/foo.vim` includes**: many runtime colorschemes have
  `source $VIMRUNTIME/colors/vim.lua` near the top — that's a base reset, not
  a separate palette. Look past it for `terminal_ansi_colors` and
  `hi Normal`.
- **Catppuccin-style flavor variants**: plugins like catppuccin or tokyonight
  ship multiple flavors (`mocha`, `frappe`, `latte`, `night`, `storm`, etc.).
  Their `:colorscheme` names are usually `<plugin>` (uses configured default)
  and `<plugin>-<flavor>`. Create a theme file per flavor you use, and
  optionally symlink `<plugin>` to your favorite default.

## Files of interest (default ghostty-mirror config)

- `~/.config/ghostty/themes/` — theme files (one per colorscheme)
- `~/.config/ghostty/config` — Ghostty's main config; must include
  `config-file = ?~/.config/ghostty/theme-current`
- `~/.config/ghostty/theme-current` — runtime state, written by the plugin

If the user has overridden `themes_dir` or `theme_file` in their `setup()`
call, use those paths instead.
