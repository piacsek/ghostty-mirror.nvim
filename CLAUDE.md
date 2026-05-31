# ghostty-mirror.nvim — project guidelines

Neovim plugin that mirrors the active colorscheme into [Ghostty](https://ghostty.org):
on `:colorscheme`, it points Ghostty's config-file include at a matching theme and
signals a reload. `:ThemeFromGhostty` goes the other way.

## Architecture

- `lua/ghostty-mirror/init.lua` — the whole plugin. Single module table `M`, ends with `return M`.
- `plugin/ghostty-mirror.lua` — auto-calls `setup()` with defaults once, guarded by `vim.g.loaded_ghostty_mirror`.
- `tests/ghostty-mirror_spec.lua` — plenary/busted spec. `tests/minimal_init.lua` bootstraps the runtimepath + plenary.

Public API surface (keep stable): `M.setup`, `M.resolve`, `M.push`, `M.generate`,
`M.write_generated`, `M.read_current`, `M.pull`, and `M.config`.

### How a theme is resolved (precedence)

1. Hand-made/cached file at `themes_dir/<name>` (honoring `light_variant_suffix` when `&background == "light"`) — wins.
2. Generated on the fly from live highlights when `config.generate` is true: `Normal` → background/foreground, `Cursor` → cursor-color, `Visual` → selection-background, `g:terminal_color_0..15` → palette. Cached to `themes_dir/<name>`.
3. If the colorscheme exposes no full `terminal_color_*` palette (or no `Normal` fg/bg), generation is skipped and `resolve` returns `nil` — never emit a partial theme.

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

- Run: `make test` (headless nvim + `PlenaryBustedDirectory`). Requires plenary on the runtimepath; `minimal_init.lua` finds it in common locations.
- CI (`.github/workflows/test.yml`) runs `make test` on Neovim **stable** and **nightly** for every push to `main` and every PR. Keep both green.
- **Every behavior change needs a test.** Reuse the spec helpers: `with_tmp_dir`, `fresh_require` (reloads the module for a clean config), `stub_system` (captures reload invocations).
- Gotcha: setting `vim.o.background` re-applies the colorscheme and clobbers manually-set highlight groups. Set `background` **before** `nvim_set_hl` in test setup.
- Tests mutating global state (`vim.o.background`, `vim.g.terminal_color_*`, highlights) must restore it — other specs depend on defaults.

## Docs

- `README.md` is user-facing and authoritative. Any config option, command, or behavior change must be reflected there (setup block, Usage, How it works).
- `.claude/skills/port-nvim-theme-to-ghostty/` is the agent skill for hand-authoring high-fidelity theme files when generation isn't good enough.
