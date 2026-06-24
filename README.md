# ghostty-mirror.nvim

<img alt="ghostty-mirror logo" src="assets/logo.png" />


Mirror Neovim's colorscheme into [Ghostty](https://ghostty.org) (and, optionally,
tmux). Run `:colorscheme foo` and Ghostty's theme flips to match — across every
open window, instantly.

https://github.com/user-attachments/assets/edb22f4a-2b3b-4704-9dae-88302277ea6e

The colorschemes in the demo are [scintilla.nvim](https://github.com/piacsek/scintilla.nvim) — my other plugin. Grab it if you like the look.

## Installation

Requires Neovim 0.10+.

### Step 1 — wire Ghostty to read the theme file

Add this to `~/.config/ghostty/config`:

```
config-file = ?~/.config/ghostty/theme-current
```

`config-file` is repeatable and `?` makes it optional (no error before the file
exists). Put it **last** so the mirrored theme overrides earlier colors.

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
  cmd = { "ThemeFromGhostty", "ThemeToGhostty", "ThemeToTmux", "ThemeCacheClear" },
  keys = { { "<M-t>", "<cmd>ThemeFromGhostty<cr>", desc = "Pull theme from Ghostty" } },
  config = function()
    local ghostty_mirror = require("ghostty-mirror")
    ghostty_mirror.setup({
       themes_dir = "~/.config/ghostty/themes",          -- where themes live / are cached
       theme_file = "~/.config/ghostty/theme-current",   -- the include file the plugin writes
       light_variant_suffix = "-light",                  -- light/dark variant routing
       generate = true,                                  -- false to require hand-made files
       reload_command = { "pkill", "-SIGUSR2", "ghostty" },
       debounce_ms = 150,                                 -- coalesce rapid switches (e.g. a picker's live preview); 0 = immediate
       overrides = {},                                    -- per-theme tweaks merged into generation (see Per-theme overrides)
       manage_background = false,                         -- opt-in: keep &background honest across switches (see Troubleshooting)
       sync_on_startup = false,                           -- opt-in: on launch, apply the theme Ghostty currently points at
       sync_on_focus = false,                             -- opt-in: on FocusGained, re-sync to the theme another nvim last wrote
       tmux = { enabled = false },                        -- opt-in tmux statusline mirroring (see below)
    })
  end,
}
```

## Usage

- `:colorscheme <name>` → Ghostty flips to the matching theme (hand-made file if
  present, otherwise generated on the fly).
- `:ThemeFromGhostty` → pull Ghostty's current theme into this Neovim instance.
  Run it in other nvim windows (across tmux panes, say) to sync them without a
  restart; `sync_on_focus = true` does this automatically on FocusGained. Inside
  tmux that needs `set -g focus-events on`. Either sync option trusts whatever
  writes `theme_file` — the name there is applied as a colorscheme automatically
  (limited to schemes you have installed).
- `:ThemeToGhostty` → force-regenerate the current scheme from live highlights,
  overwriting a cached file. Handy after tweaking a scheme's options. A hand-made
  file is refused; `:ThemeToGhostty!` overwrites it too (the bang covers only the
  Ghostty file — tmux takes its own `:ThemeToTmux!`).
- `:ThemeToTmux` → tmux analog of `:ThemeToGhostty`, bang included (when tmux
  mirroring is enabled).
- `:ThemeCacheClear` → delete generated theme files (recognized by their header
  line), leaving hand-made ones untouched. Use it when a cached theme goes stale;
  the next `:colorscheme` regenerates fresh.

Background and foreground mirror for *any* colorscheme; the ANSI `palette` only
when the scheme sets its own `g:terminal_color_*` (some, like catppuccin, gate it
behind `term_colors`). To override generation, drop a hand-made
`themes_dir/<name>` — it always wins.

### tmux

1. Opt in to mirror the colorscheme into tmux's statusline too:

```lua
require("ghostty-mirror").setup({
  tmux = {
    enabled = true,                                  -- off by default
    themes_dir = "~/.config/tmux/themes",            -- per-theme .conf files live / are cached here
    theme_file = "~/.config/tmux/theme-current.conf",-- pointer file the plugin writes + sources
    bar_blend = 0.22,                                -- status bar = Normal bg blended this far toward the accent
    accent_hl = "Type",                              -- highlight group whose fg is the bright accent (selected window)
    divider_hl = "WinSeparator",                     -- inactive pane border color
    selection_hl = "Visual",                         -- highlight group whose bg colors the copy-mode selection (mode-style)
    overrides = {},                                  -- per-theme tweaks, see below
    -- reload_command = { "tmux", "source-file", "<theme_file>" },  -- default; override to taste
  },
})
```

2. `tmux.conf` changes

Add the following to your tmux config file:

```tmux
   if-shell "test -f ~/.config/tmux/theme-current.conf" \
     "source-file ~/.config/tmux/theme-current.conf"
```

Note: your tmux config **must not** contain colour-related settings or plugins,
or they'll fight the mirrored theme.

To hand-author a theme instead, drop a `themes_dir/<name>.conf` — it always wins
over generation, like Ghostty ([guide](docs/manual_tmux_themes.md)).

### Per-theme overrides

When generation is almost right, tweak a single theme from config instead of
hand-authoring a whole file. Top-level `overrides` for Ghostty, `tmux.overrides`
for tmux:

```lua
require("ghostty-mirror").setup({
  overrides = {
    ron = {
      cursor_color = "#ffaabb",
      palette = { [3] = "#cc8800" },
    },
  },
  tmux = {
    overrides = {
      ron = { accent = "#fff", divider = "#ccc", bar_blend = 0.3, selection = "#445" },
    },
  },
})
```

### Cursor color

The generated theme includes a `cursor-color`, but **Ghostty only applies it on a
full restart** — not on a live reload, so the cursor won't follow `:colorscheme`
through the plugin alone. For a theme-following cursor *inside Neovim*, point
`guicursor` at the `Cursor` highlight so Neovim sets it itself (via OSC 12):

```lua
vim.opt.guicursor = "n-v-c-sm:block-Cursor/lCursor,"
  .. "i-ci-ve:ver25-Cursor/lCursor,r-cr-o:hor20-Cursor/lCursor,"
  .. "t:block-blinkon500-blinkoff500-TermCursor"
```

## Troubleshooting

Run `:checkhealth ghostty-mirror` first — it flags the common environmental
causes: a missing `config-file` include ([Step 1](#step-1--wire-ghostty-to-read-the-theme-file)),
un-writable `themes_dir`/`theme_file`, a `reload_command` not on `$PATH`, Ghostty
not running, tmux enabled but not running.

- **Initial load.** The plugin doesn't fire on Neovim's startup colorscheme, so
  opening a new window won't reflow Ghostty. To have a fresh nvim follow Ghostty's
  current theme, set `sync_on_startup = true` (applies `theme_file` on `VimEnter`),
  or read it yourself:

  ```lua
  local lines = vim.fn.readfile(vim.fn.expand("~/.config/ghostty/theme-current"))
  local theme = lines[1] and lines[1]:match("theme%s*=%s*(%S+)")
  if theme then pcall(vim.cmd.colorscheme, theme) end
  ```

- **`SIGUSR2` reloads all Ghostty windows.** That's how Ghostty's config reload
  works today — no per-window override. Switching themes in any nvim flips every
  window.

- **Plugin colorschemes load late.** Setting `:colorscheme some-plugin` in
  `init.lua` before plugins load fails — wrap it in `pcall` and retry on
  `VimEnter`. Normal use is unaffected.

- **A light scheme can leave `&background` stuck.** Some schemes (catppuccin-latte)
  set `background=light` and never reset it, so an adaptive scheme loaded after
  (the built-in `default`) renders its *light* variant — which the plugin
  faithfully mirrors. If `default` looks washed-out after a light scheme, that's
  why. Set `manage_background = true` to have the plugin handle it, or wire the
  autocmds yourself.

  <details>
  <summary>Autocmds that keep <code>&background</code> honest</summary>

  ```lua
  -- Baseline &background to dark before a scheme loads, then sync it to the
  -- loaded scheme's actual Normal-bg luminance. Both writes are guarded, since
  -- writing &background re-applies the scheme and re-fires these events.
  local group = vim.api.nvim_create_augroup("background-honest", { clear = true })
  local adjusting = false
  local function set_bg(want)
  	if vim.o.background ~= want then
  		adjusting = true
  		vim.o.background = want
  		adjusting = false
  	end
  end
  vim.api.nvim_create_autocmd("ColorSchemePre", {
  	group = group,
  	callback = function() if not adjusting then set_bg("dark") end end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
  	group = group,
  	callback = function()
  		if adjusting then return end
  		local n = vim.api.nvim_get_hl(0, { name = "Normal" })
  		if type(n.bg) ~= "number" then return end
  		local r, g, b = math.floor(n.bg / 65536) % 256, math.floor(n.bg / 256) % 256, n.bg % 256
  		set_bg((0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.5 and "light" or "dark")
  	end,
  })
  ```
  </details>

## Development

Plenary-based test suite. With plenary installed via your plugin manager (or
fetched into `~/.local/share/nvim/site/pack/vendor/start/`), run:

```sh
make test
```

CI runs the same on stable and nightly Neovim.

See the [roadmap](ROADMAP.md) for planned milestones.

## License

MIT
