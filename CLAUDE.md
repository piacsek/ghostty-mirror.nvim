# ghostty-mirror.nvim — project guidelines

Neovim plugin that mirrors the active colorscheme into [Ghostty](https://ghostty.org):
on `:colorscheme`, it points Ghostty's config-file include at a matching theme and
signals a reload. `:ThemeFromGhostty` goes the other way. Targets Neovim **0.10+**
(uses `vim.uv` and `nvim_get_hl{ link = false }`).

## Architecture

- `lua/ghostty-mirror/init.lua` — the whole plugin. Single module table `M`, ends with `return M`.
- `lua/ghostty-mirror/health.lua` — `:checkhealth ghostty-mirror` provider (`M.check`, plus a unit-testable `M.diagnostics` and overridable `M.ghostty_running`/`M.ghostty_config_paths`). Includes the config-file include-wiring check (warns with the exact line to add).
- `plugin/ghostty-mirror.lua` — auto-calls `setup()` with defaults once, guarded by `vim.g.loaded_ghostty_mirror`.
- `doc/ghostty-mirror.txt` — vimdoc (`:help ghostty-mirror`).
- `tests/ghostty-mirror_spec.lua` — plenary/busted spec. `tests/minimal_init.lua` bootstraps the runtimepath + plenary.

Public API surface (keep stable): `M.setup`, `M.resolve`, `M.push`, `M.generate`,
`M.write_generated`, `M.read_current`, `M.pull`, `M.clear_cache`, `M.current_scheme`,
and `M.config` (plus the `ghostty-mirror.health` module's
`M.check`/`M.diagnostics`/`M.ghostty_running`/`M.ghostty_config_paths`).
tmux mirroring (opt-in via `config.tmux.enabled`) adds siblings: `M.generate_tmux`,
`M.resolve_tmux`, `M.write_tmux_generated`, `M.push_tmux` — structured exactly like
their Ghostty counterparts (same precedence). The tmux accent is the fg of a
highlight group (`accent_hl`, default `Type`) so it harmonizes with each scheme's
hue; the bar blends toward it and the selected-window text is contrast-picked.
The copy-mode selection (`mode-style`) instead mirrors `selection_hl` (default
`Visual`) — its bg, with its fg honored when present else contrast-picked —
decoupling the selection from the accent; it falls back to the accent pill only
when that group has no bg.
Per-theme overrides (keyed by resolved name; `cyberdream`/`cyberdream-light` separate) merge
into generation on both sides: top-level `overrides` for Ghostty — five emitted
color keys as Lua-friendly underscores mapped to dashed directives
(`cursor_color` → `cursor-color`; color params replace the highlight-derived value
and force-emit the conditional directives; deliberately **no `background`** — the
terminal background diverging from the editor's is the mismatch the plugin
exists to prevent) plus individual `palette` slots, which substitute into an
owned palette and emit a partial one when the scheme owns none — and
`tmux.overrides` for tmux, replacing generation's inputs
(`accent`/`divider`/`bar`/`bar_blend`/`selection`). The effective set is stamped into the
generated file's header (`# overrides: ...`, palette slots flattened to
`paletteN`) and both resolvers regenerate on a stamp mismatch — that's how
override edits apply without `:ThemeCacheClear`. The resolvers' second return
value (`regenerated`) makes both pushes reload even under an unchanged pointer.
Setup warns on overrides that can't take effect; generation falls back on bad
values. Hand-made files are never modified by overrides.

Commands: `:ThemeFromGhostty` (pull), `:ThemeToGhostty`/`:ThemeToTmux` (force-push,
immediate; a hand-made target is refused without the bang), `:ThemeCacheClear` (delete generated theme files, leaving hand-made ones).

### How a theme is resolved (precedence)

1. Hand-made/cached file at `themes_dir/<name>` (honoring `light_variant_suffix` when `&background == "light"`) — wins.
2. Generated on the fly from live highlights when `config.generate` is true: `Normal` → background/foreground, `Cursor` → cursor-color, `Visual` → selection-background, `g:terminal_color_0..15` → palette. Cached to `themes_dir/<name>`.
3. The highlight-derived colors (`Normal`/`Cursor`/`Visual`) are always the colorscheme's own, so they're mirrored unconditionally. The 16-color palette is appended **only** when the scheme actually owns a full `terminal_color_*` palette (it changed it on this `:colorscheme`) — `terminal_color_*` is global and sticky, so a scheme that sets none of its own would otherwise mirror an inherited palette. Generation returns `nil` (and nothing is mirrored) only when `Normal` has no fg/bg to anchor the theme.

The plugin owns **only** the include file (`theme_file`) and the themes it generates.
It must not touch the user's main Ghostty config or their hand-made theme files.

The `ColorScheme` autocmd is **debounced** (`config.debounce_ms`, default 150) — a
colorscheme picker's live preview fires the event per previewed scheme, so we
coalesce and `M.push` only once the scheme settles. `:ThemeToGhostty`/`:ThemeToTmux`
call `M.push` directly, so they stay immediate.

### Debugging a "stuck" / desynced theme

Almost always the *environment*, not the plugin (which faithfully mirrors the last
settled `:colorscheme`). Suspect, in order: a colorscheme **picker** spraying
transient previews (the debounce is the fix — check it's not set to 0); a config
that **reads `theme_file` at startup** to pick the colorscheme (input+output =
feedback loop); and **multiple nvim instances** sharing one `theme_file`
(last-writer-wins by design — that's how `:ThemeFromGhostty` syncs windows).
Recovery: kill all nvims, pre-set `theme_file` (+ tmux pointer) to the wanted
theme, restart. `colors_name == nil` means a colorscheme load aborted upstream —
not a mirror issue.

An override that "doesn't work" usually *did* land in the theme file — another
layer is painting the pixel. nvim paints its own cells (Normal/Visual/Cursor),
tmux copy-mode paints mouse selections (`mode-style`, from `selection_hl` — the Visual highlight by default);
Ghostty's colors show at the prompt, padding, and Shift+drag selections. Check
the generated file first: if the override is in it, the plugin is done and the
question is which layer renders what the user is looking at. (Cursor colors
additionally need a full Ghostty restart.)

## Conventions

- **Indentation:** tabs (see existing files / `.editorconfig` if added).
- **Annotations:** LuaCATS/EmmyLua on every public function and the config class (`---@class`, `---@field`, `---@param`, `---@return`). Match the existing density.
- **Comments:** explain *why*, not *what*. Terse. The existing files set the bar.
- **Neovim APIs:** prefer `vim.uv`, `vim.system`, `vim.api.nvim_*`, `vim.fn.*` over shelling out. Detach long-running subprocesses (`{ detach = true }`).
- **Config:** all behavior is driven by `M.config` merged from `defaults` via `vim.tbl_deep_extend("force", ...)`. New options need a default, a `---@field` doc, a README entry, and a vimdoc entry.
- **No-op, but never silently:** when inputs are missing/incomplete, no-op rather than writing something Ghostty, nvim, or tmux can't load or that looks wrong — but config is always parsed/validated and a rejected value draws a `vim.notify(..., WARN)` saying why (the setup-time override warnings are the pattern). Environment issues (Ghostty not running, include not wired, bad paths) surface through `health.lua` diagnostics, not notifications — keep `:checkhealth` thorough when adding environment-dependent behavior.

## Workflow

How the user likes work to flow — follow it unless told otherwise:

1. **Plan as a concrete task list.** Break the request into small, ordered tasks, each independently testable and committable. Work them top to bottom.
2. **Drive each task with the `/tdd` skill.** Failing spec first, make it pass, refactor — small increments. Behavior changes start from a test, never from the implementation. Where the skill says the *user* commits checkpoints, this repo overrides it: the agent commits and pushes per task (see below), no need to ask.
3. **One commit per task.** A task is done when its specs are green (`make test`), `make lint` is clean, and the docs are consistent — anything the task touched that's user-visible reads the same in `README.md` and `doc/ghostty-mirror.txt`, including examples (a wiring example that omits a step its own prose prescribes is drift too). Then, per task:
   - commit with a clear message and **push straight to `main`** — no feature branch or PR (standing preference);
   - update the locally-installed copy so it's testable in the user's running Neovim — installed via `vim.pack` at `~/.local/share/nvim/site/pack/core/opt/ghostty-mirror.nvim`, so refresh it through `vim.pack` (e.g. `:lua vim.pack.update({ "ghostty-mirror.nvim" })`), **not** a manual `git -C <path> pull`. `:checkhealth ghostty-mirror` reports the version diff when it reads the `vim.pack` lock file, so it flags when the installed copy is behind `main`. The user then restarts Neovim (or re-`require`s the module) to load it.
4. **Never cut a release on your own.** Tags / version bumps happen **only when explicitly asked**.

## Testing

- Run: `make test` (headless nvim + `PlenaryBustedDirectory`). Requires plenary on the runtimepath; `minimal_init.lua` finds it in common locations.
- Run `make lint` (stylua, config in `stylua.toml`) before pushing; `stylua .` to fix. Both `make test` and `make lint` are the quality gates. On this machine `stylua` lives at `~/.local/share/nvim/mason/bin/stylua` (Mason), not on the default PATH.
- CI (`.github/workflows/test.yml`) runs `make test` on Neovim **stable** and **nightly**, plus a stylua lint job, for every push to `main` and every PR. Keep them green.
- **Every behavior change needs a test.** Reuse the spec helpers: `with_tmp_dir`, `fresh_require` (reloads the module for a clean config), `stub_system` (captures reload invocations).
- Gotcha: setting `vim.o.background` re-applies the colorscheme and clobbers manually-set highlight groups. Set `background` **before** `nvim_set_hl` in test setup.
- Tests mutating global state (`vim.o.background`, `vim.g.terminal_color_*`, highlights) must restore it — other specs depend on defaults.

## Docs

- `README.md` is user-facing and authoritative. Any config option, command, or behavior change must be reflected there (setup block, Usage, How it works) **and** in the vimdoc at `doc/ghostty-mirror.txt` — the two must not drift.
- `ROADMAP.md` lists **major and minor milestones only** (newest first, planned work on top). Patch releases are documented in GitHub releases, never as roadmap entries — at most a one-line "later X.Y.x patches ..." mention inside the parent minor's entry. A minor/major release adds its entry and renumbers any planned ones it displaced.
- **Word choice:** prefer "Considerations" over "Caveats" — "caveat" reads as a gotcha/warning, which is off-putting for a plugin. Same for headings and inline ("two considerations", not "two caveats").
- **No emojis** anywhere — README, release notes, commit messages, headings. Plain text only.
- **Only real theme names in docs** (README, vimdoc, CLAUDE.md, LuaCATS annotations): built-ins (`ron`, `elflord`) or real plugins (`cyberdream`). Never invent one — a light-variant example is `cyberdream-light` (an actual scheme), not `ron-light` (doesn't exist). Placeholder names like `mytheme` stay confined to tests.
- **Conciseness beats verbosity.** Keep docs to the point and expose what matters; don't restate the same idea in two places, and cut step-lists that prose covers. Every load-bearing fact stays, but say it once.
- `.claude/skills/port-nvim-theme-to-ghostty/` is the agent skill for hand-authoring high-fidelity theme files when generation isn't good enough.
