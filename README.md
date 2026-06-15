# ghostty-mirror.nvim

<img alt="ghostty-mirror logo" src="assets/logo.png" />


Mirror Neovim's colorscheme into [Ghostty](https://ghostty.org) (and, optionally,
tmux). When you run `:colorscheme foo` in Neovim, Ghostty's terminal theme flips
to match — across every open window, instantly.

https://github.com/user-attachments/assets/edb22f4a-2b3b-4704-9dae-88302277ea6e

The colorschemes in the demo are [scintilla.nvim](https://github.com/piacsek/scintilla.nvim) — my other plugin. Grab it if you like the look.

## Installation

Requires Neovim 0.10+.

### Step 1 — wire Ghostty to read the theme file

Add this to `~/.config/ghostty/config`:

```
config-file = ?~/.config/ghostty/theme-current
```

`config-file` is repeatable (won't clash with existing ones) and `?` makes it
optional (no error before the file exists). Put it **last** so the mirrored
theme overrides colors set earlier in your config.

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
  keys = { { "<M-t>", desc = "Pull theme from Ghostty" } },
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

- `:colorscheme <name>` in Neovim → Ghostty flips to the matching theme
  (hand-made file if present, otherwise generated on the fly).
- `:ThemeFromGhostty` → pull Ghostty's current theme into this Neovim instance.
  Run this in other nvim windows (across tmux panes, for example) to keep them
  in sync without restarting them. Set `sync_on_focus = true` to do this
  automatically whenever a window regains focus. Inside tmux this needs
  `set -g focus-events on` in your `tmux.conf`, otherwise tmux swallows the
  focus events and panes won't re-sync on switch. One consideration: either
  sync option trusts whatever can write `theme_file` — a name written there
  is applied as a colorscheme automatically (limited to schemes you have
  installed).
- `:ThemeToGhostty` → force-regenerate the current colorscheme's theme from
  live highlights, overwriting a cached file. Handy after you tweak a
  colorscheme's options and want Ghostty to pick up the new colors. A
  hand-made theme file is refused with a warning — `:ThemeToGhostty!`
  overwrites it too. The bang covers only the Ghostty file: the tmux push it
  chains into (when mirroring is enabled) still refuses a hand-made `.conf`,
  which takes its own `:ThemeToTmux!`.
- `:ThemeToTmux` → force-regenerate the current colorscheme's tmux theme (when
  tmux mirroring is enabled). The tmux analog of `:ThemeToGhostty`, bang
  included.
- `:ThemeCacheClear` → delete generated theme files (recognized by their header
  line — an edited file keeping it still counts as generated), leaving hand-made
  ones untouched. Use it when a cached theme has gone stale; the next
  `:colorscheme` regenerates fresh.

Background and foreground mirror for *any* colorscheme; the ANSI `palette` only
when the scheme sets its own `g:terminal_color_*` (some, like catppuccin, gate
it behind `term_colors`). See [How it works](#how-it-works) for the details and
the hand-made-file escape hatch.

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

Note: For a fully functional integration, your tmux config **must not** contain any colour-related settings or plugins.

To hand-author a theme instead of generating one, drop a
`themes_dir/<name>.conf` — it always wins over generation, exactly like Ghostty
([guide](docs/manual_tmux_themes.md)).

### Per-theme overrides

When generation is almost right, tweak a single theme from config instead of
hand-authoring a whole file. Both targets take the same shape: top-level
`overrides` for Ghostty themes, `tmux.overrides` for tmux:

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
      ron = { accent = "#fff", divider = "#ccc", bar_blend = 0.3 },
    },
  },
})
```

### Cursor color

The generated theme includes a `cursor-color`, but **Ghostty only applies it on
a full restart** — it isn't re-read on a live config reload. So the cursor
won't follow `:colorscheme` through ghostty-mirror alone. To get a
theme-following cursor *inside Neovim*, point `guicursor` at the `Cursor`
highlight so Neovim sets the cursor color itself (via OSC 12):

```lua
vim.opt.guicursor = "n-v-c-sm:block-Cursor/lCursor,"
  .. "i-ci-ve:ver25-Cursor/lCursor,r-cr-o:hor20-Cursor/lCursor,"
  .. "t:block-blinkon500-blinkoff500-TermCursor"
```

## Troubleshooting

Run `:checkhealth ghostty-mirror` first — it flags the common environmental
causes (a missing `config-file` include in your Ghostty config — the [Step 1](#step-1--wire-ghostty-to-read-the-theme-file)
wiring — un-writable `themes_dir`/`theme_file`, a `reload_command` not on
`$PATH`, no running Ghostty, tmux enabled but not running).

- **Initial load.** The plugin doesn't fire on Neovim's startup colorscheme;
  opening a new nvim window won't reflow every Ghostty window. To have a
  freshly-opened nvim follow Ghostty's current theme instead, set
  `sync_on_startup = true` (it applies the theme from `theme_file` on
  `VimEnter`), or read it yourself:

  ```lua
  local lines = vim.fn.readfile(vim.fn.expand("~/.config/ghostty/theme-current"))
  local theme = lines[1] and lines[1]:match("theme%s*=%s*(%S+)")
  if theme then pcall(vim.cmd.colorscheme, theme) end
  ```

- **`SIGUSR2` reloads all Ghostty windows.** That's how Ghostty's config
  reload works today — there's no per-window override. Switching themes in
  any nvim flips every Ghostty window.

- **Plugin colorschemes load late.** Setting `:colorscheme some-plugin` in
  `init.lua` before plugins load fails — wrap it in `pcall` and retry on
  `VimEnter`. Normal use is unaffected.

- **A light scheme can leave `&background` stuck.** Some schemes (catppuccin-latte)
  set `background=light` and never reset it, so an `&background`-adaptive scheme
  loaded afterwards (the built-in `default`) renders its *light* variant — which
  the plugin faithfully mirrors. If `default` looks washed-out after a light
  scheme, that's the cause. Set `manage_background = true` to have the plugin
  handle it, or wire the autocmds yourself.

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

The plugin has a plenary-based test suite. With plenary installed via your
plugin manager (or fetched into `~/.local/share/nvim/site/pack/vendor/start/`),
run:

```sh
make test
```

CI runs the same on stable and nightly Neovim.

See the [roadmap](ROADMAP.md) for planned milestones.

## License

MIT
