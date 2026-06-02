# ghostty-mirror.nvim — project guidelines

Neovim plugin that mirrors the active colorscheme into [Ghostty](https://ghostty.org):
on `:colorscheme`, it points Ghostty's config-file include at a matching theme and
signals a reload. `:ThemeFromGhostty` goes the other way.

## Architecture

- `lua/ghostty-mirror/init.lua` — the whole plugin. Single module table `M`, ends with `return M`.
- `plugin/ghostty-mirror.lua` — auto-calls `setup()` with defaults once, guarded by `vim.g.loaded_ghostty_mirror`.
- `tests/ghostty-mirror_spec.lua` — plenary/busted spec. `tests/minimal_init.lua` bootstraps the runtimepath + plenary.

Public API surface (keep stable): `M.setup`, `M.resolve`, `M.push`, `M.generate`,
`M.write_generated`, `M.read_current`, `M.pull`, `M.clear_cache`, and `M.config`.
tmux mirroring (opt-in via `config.tmux.enabled`) adds siblings: `M.generate_tmux`,
`M.resolve_tmux`, `M.write_tmux_generated`, `M.push_tmux` — structured exactly like
their Ghostty counterparts (same precedence). The tmux accent is the fg of a
highlight group (`accent_hl`, default `Type`) so it harmonizes with each scheme's
hue; the bar blends toward it and the selected-window text is contrast-picked.

### How a theme is resolved (precedence)

1. Hand-made/cached file at `themes_dir/<name>` (honoring `light_variant_suffix` when `&background == "light"`) — wins.
2. Generated on the fly from live highlights when `config.generate` is true: `Normal` → background/foreground, `Cursor` → cursor-color, `Visual` → selection-background, `g:terminal_color_0..15` → palette. Cached to `themes_dir/<name>`.
3. The highlight-derived colors (`Normal`/`Cursor`/`Visual`) are always the colorscheme's own, so they're mirrored unconditionally. The 16-color palette is appended **only** when the scheme actually owns a full `terminal_color_*` palette (it changed it on this `:colorscheme`) — `terminal_color_*` is global and sticky, so a scheme that sets none of its own would otherwise mirror an inherited palette. Generation returns `nil` (and nothing is mirrored) only when `Normal` has no fg/bg to anchor the theme.

The plugin owns **only** the include file (`theme_file`) and the themes it generates.
It must not touch the user's main Ghostty config or their hand-made theme files.

## Conventions

- **Indentation:** tabs (see existing files / `.editorconfig` if added).
- **Annotations:** LuaCATS/EmmyLua on every public function and the config class (`---@class`, `---@field`, `---@param`, `---@return`). Match the existing density.
- **Comments:** explain *why*, not *what*. Terse. The existing files set the bar.
- **Neovim APIs:** prefer `vim.uv`, `vim.system`, `vim.api.nvim_*`, `vim.fn.*` over shelling out. Detach long-running subprocesses (`{ detach = true }`).
- **Config:** all behavior is driven by `M.config` merged from `defaults` via `vim.tbl_deep_extend("force", ...)`. New options need a default, a `---@field` doc, and a README entry.
- **Fail silently, never wrongly:** when inputs are missing/incomplete, no-op rather than writing something Ghostty can't load or that looks wrong.

## Testing

- **Default workflow: use the `/tdd` skill** to iterate on this repo — write a failing spec first, make it pass, refactor, in small increments. Behavior changes start from a test, not from the implementation.
- Run: `make test` (headless nvim + `PlenaryBustedDirectory`). Requires plenary on the runtimepath; `minimal_init.lua` finds it in common locations.
- CI (`.github/workflows/test.yml`) runs `make test` on Neovim **stable** and **nightly** for every push to `main` and every PR. Keep both green.
- **Every behavior change needs a test.** Reuse the spec helpers: `with_tmp_dir`, `fresh_require` (reloads the module for a clean config), `stub_system` (captures reload invocations).
- Gotcha: setting `vim.o.background` re-applies the colorscheme and clobbers manually-set highlight groups. Set `background` **before** `nvim_set_hl` in test setup.
- Tests mutating global state (`vim.o.background`, `vim.g.terminal_color_*`, highlights) must restore it — other specs depend on defaults.
- A successful iteration (specs green via `make test`) can be committed and pushed to `main`.
- **Push straight to `main`.** No feature branch or PR needed — commit and push directly (the user's standing preference).
- After committing/pushing, update the locally-installed copy so the change is testable in the user's running Neovim. It's installed via `vim.pack` at `~/.local/share/nvim/site/pack/core/opt/ghostty-mirror.nvim` — `git -C <that path> pull --ff-only origin main`. The user then restarts Neovim (or re-`require`s the module) to load it.

## Docs

- `README.md` is user-facing and authoritative. Any config option, command, or behavior change must be reflected there (setup block, Usage, How it works).
- **Word choice:** prefer "Considerations" over "Caveats" — "caveat" reads as a gotcha/warning, which is off-putting for a plugin. Same for headings and inline ("two considerations", not "two caveats").
- `.claude/skills/port-nvim-theme-to-ghostty/` is the agent skill for hand-authoring high-fidelity theme files when generation isn't good enough.
