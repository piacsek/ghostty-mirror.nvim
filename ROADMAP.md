# Roadmap

Milestones for ghostty-mirror.nvim, newest first (planned work at the top).
Major and minor versions only — patch releases are documented in the
[GitHub releases](https://github.com/piacsek/ghostty-mirror.nvim/releases).

## 0.7.0 — Granular tmux overrides (planned)

Detach the tmux colors that are currently welded to the single `accent`
input, starting with `copy_mode`: today `mode-style` (the copy-mode mouse
selection) follows the accent, so "magenta selections, blue everything else"
isn't expressible. A `copy_mode` override param sets it directly, with the
selection text contrast-picked and everything else (pill, active border,
status-right, clock) staying on `accent`. Unset keeps today's output
byte-identical. Further params may follow the same pattern as needs surface.

## 0.6.0 — Force-push safety and link-proof writes

Both actionable findings from the security scan in issue #15.
`:ThemeToGhostty`/`:ThemeToTmux` now refuse to overwrite a hand-made theme
file unless banged (`:ThemeToGhostty!`), closing the one path where the
plugin could destroy a file it doesn't own — `M.push`/`M.push_tmux` grew a
matching `clobber` opt. And the write proof that refuses symlinked
destinations now refuses hard links too (`nlink == 1`), so a planted link of
either kind can't redirect a theme write into another file.

## 0.5.0 — Per-theme Ghostty overrides

Extend 0.4.0's override machinery to the Ghostty generation path —
`overrides = { ron = { cursor_color = "#ffaabb", palette = { [3] = "#cc8800" } } }` —
with `foreground`, `cursor_color`, `cursor_text`, `selection_background`,
`selection_foreground` and individual `palette` slots (0..15), keyed by
resolved theme name. Same semantics as the tmux side: stamped caches
regenerate seamlessly on a config edit, setup warns about overrides that
can't take effect (including palette slots), bad values fall back to the
highlight-derived colors, and hand-made files stay untouched. Deliberately
no `background` param — the terminal background diverging from the editor's
is the mismatch the plugin exists to prevent. Docs gained a "Who paints
what" table mapping each pixel to the layer that owns it (nvim highlights,
tmux copy-mode, Ghostty). Later 0.5.x patches taught `:checkhealth` to flag
a missing `config-file` include line, made `:ThemeFromGhostty` warn instead
of throw on an uninstalled scheme, backfilled the issue #7 coverage audit,
and worked through a series of security reviews' filesystem hardening
(issues #8–#14).

## 0.4.0 — Per-theme tmux overrides

Tweak the generated tmux theme per colorscheme via config — e.g.
`tmux = { overrides = { ron = { accent = "#fff", bar = "#3a0054" } } }` —
with `accent`, `divider`, `bar`, and `bar_blend` params keyed by resolved
theme name. The effective overrides are stamped into the generated file, so
a config edit regenerates the cache and reloads tmux on the next
`:colorscheme` or restart; setup warns about overrides that can't take
effect (unknown theme, unknown param, invalid value), and hand-made themes
keep winning, untouched. Also fixed the startup/focus sync to re-fire the
mirror chain (`nested` autocmds) and sandboxed `$HOME` in the test suite so
specs can never touch a real Ghostty/tmux config.

## 0.3.0 — Sync controls, performance, and polish

- **`manage_background`** (opt-in) — keep `&background` honest across switches
  so adaptive schemes don't inherit a stale light/dark.
- **`sync_on_startup`** (opt-in) — on launch, apply the theme Ghostty currently
  points at.
- **`sync_on_focus`** (opt-in) — on `FocusGained`, re-sync to the theme another
  nvim instance last wrote, keeping panes in step.
- **Performance** — skip the rewrite + reload when the resolved theme is
  unchanged, so idempotent `:colorscheme` events don't reload every Ghostty
  window.
- **Robustness** — `push`/`push_tmux` no-op on an empty colorscheme name; health
  now detects a running Ghostty.
- **Docs and infra** — vimdoc (`:help ghostty-mirror`) and a stylua lint gate
  in CI.

0.3.1 worked through an external code review (issue #3) end to end: name
sanitization ahead of paths and commands, fail-fast config validation, setup
lifecycle cleanup, a Neovim 0.10+ version floor, and coverage growth to 90
specs.

## 0.2.0 — tmux support

Mirror the active colorscheme into tmux's statusline too (opt-in), keeping
terminal, Ghostty, and tmux in sync on `:colorscheme`. The accent is sourced
from a highlight group so it harmonizes with each scheme's hue, with
light-theme handling and contrast-picked text. 0.2.1 added
`:checkhealth ghostty-mirror`, mirrored `selection-foreground`/`cursor-text`,
and fixed light/dark variant resolution.

## 0.1.0 — Theme auto-generation

Generate a Ghostty theme on the fly from the active colorscheme's live
highlights when no hand-made/cached file exists, so any colorscheme mirrors
without manual authoring. Later 0.1.x patches added `:ThemeCacheClear`, gated
the ANSI palette so only a scheme's own `terminal_color_*` is mirrored, and
documented the cursor-color reload limitation.
