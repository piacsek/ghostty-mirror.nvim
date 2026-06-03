# Roadmap

Released milestones for ghostty-mirror.nvim (newest planned work at the bottom).

## 0.1.0 — Theme auto-generation

Generate a Ghostty theme on the fly from the active colorscheme's live
highlights when no hand-made/cached file exists, so any colorscheme mirrors
without manual authoring. Later 0.1.x patches added `:ThemeCacheClear`, gated
the ANSI palette so only a scheme's own `terminal_color_*` is mirrored, and
documented the cursor-color reload limitation.

## 0.2.0 — tmux support

Mirror the active colorscheme into tmux's statusline too (opt-in), keeping
terminal, Ghostty, and tmux in sync on `:colorscheme`. The accent is sourced
from a highlight group so it harmonizes with each scheme's hue, with
light-theme handling and contrast-picked text. 0.2.1 added
`:checkhealth ghostty-mirror`, mirrored `selection-foreground`/`cursor-text`,
and fixed light/dark variant resolution.

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

## 0.3.1 — Hardening and coverage

Worked through an external code review (issue #3) end to end:

- **Name sanitization** — colorscheme names are gated on a safe character
  whitelist before reaching filesystem paths, the Ghostty pointer file, or the
  tmux `source-file` command, closing path-traversal and injection routes.
- **Config validation** — `setup` fails fast with the offending field's name
  on a misshapen config (e.g. `tmux = true`) instead of erroring deep inside a
  later push.
- **Setup lifecycle** — a pending debounced push is cancelled on re-`setup()`
  and at shutdown, so stale pushes can't fire under a new config or into a
  dying editor.
- **Version floor** — Neovim 0.10+ is enforced at setup with a clear error and
  documented in README and vimdoc.
- **Coverage** — the suite grew from 74 to 90 specs, pinning the
  generate/clear-cache marker round-trip, the single-reload guarantee of the
  `manage_background` cascade, and the startup-sync immediate branch.

## 0.4.0 — Per-theme tmux overrides (planned)

Let users tweak the auto-generated tmux theme per colorscheme via config
(e.g. `tmux = { overrides = { ron = { accent = "#fff" } } }`), merged into
generation without hand-authoring a whole theme file. Override changes apply
seamlessly on the next reload; hand-made themes keep winning, untouched.

## 0.5.0 — Ghostty per-theme overrides (planned)

Extend the same override machinery to the Ghostty generation path.
