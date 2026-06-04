-- ghostty-mirror.nvim
-- Mirror Neovim's colorscheme into Ghostty so the terminal flips themes the
-- moment you change colorschemes in nvim.

local M = {}

-- Every field is optional ("?"): setup() merges over defaults, so user configs
-- are partial by design and must not trip lua_ls's missing-fields check.
---@class GhosttyMirrorConfig
---@field themes_dir? string Directory Ghostty reads themes from. Defaults to ~/.config/ghostty/themes.
---@field theme_file? string Path Ghostty reads the active theme from via config-file include. Defaults to ~/.config/ghostty/theme-current.
---@field light_variant_suffix? string Suffix used when looking for light-mode variant files (e.g. "cyberdream-light"). Letters, digits, '.', '_' and '-' only; setup() errors otherwise. Set to "" or false to disable.
---@field generate? boolean When no theme file exists for a colorscheme, generate one on the fly from Neovim's live highlights and terminal_color_* palette, caching it to themes_dir. Skips silently if the palette is incomplete. Defaults to true.
---@field reload_command? string[] Command + args used to tell Ghostty to reload its config. Defaults to `pkill -SIGUSR2 ghostty`.
---@field debounce_ms? integer Coalesce rapid :colorscheme changes (e.g. a picker's live preview) and only mirror once the scheme settles, this many ms after the last change. 0 mirrors synchronously on every change. Defaults to 150.
---@field overrides? table<GhosttyMirrorThemeName, GhosttyMirrorGhosttyOverride> Per-theme tweaks merged into Ghostty theme generation, keyed by resolved theme name (the light variant keys separately, e.g. "cyberdream-light"). Defaults to {}.
---@field manage_background? boolean Opt-in: keep &background honest across :colorscheme switches. Baselines &background to dark before a scheme loads (so &background-adaptive schemes like `default` don't inherit a stale light from a previous light scheme) then syncs it to the loaded scheme's Normal-bg luminance. Defaults to false.
---@field sync_on_startup? boolean Opt-in: on setup (or VimEnter), apply the colorscheme named in theme_file so a freshly-opened nvim follows Ghostty's current theme. Defaults to false.
---@field sync_on_focus? boolean Opt-in: on FocusGained, apply the colorscheme named in theme_file when it differs from the one this instance loaded, so multiple nvim instances re-sync to whichever last wrote the theme. Defaults to false.
---@field tmux? GhosttyMirrorTmuxConfig Opt-in tmux statusline mirroring. Disabled by default.

---The resolved theme name a generated theme is written under: an installed
---colorscheme's name, or its light variant with `light_variant_suffix`
---appended (e.g. "cyberdream", "cyberdream-light"). setup() warns when it matches neither.
---@alias GhosttyMirrorThemeName string

-- Lua-friendly underscore params; generation maps them to Ghostty's dashed
-- directives (cursor_color -> cursor-color). Deliberately no `background`:
-- the terminal background diverging from the editor's is exactly the mismatch
-- the plugin exists to prevent.
---@class GhosttyMirrorGhosttyOverride
---@field foreground? string Replaces the Normal-fg-derived foreground ("#rgb" or "#rrggbb").
---@field cursor_color? string Replaces the Cursor-derived cursor-color; emitted even when the highlight lacks one.
---@field cursor_text? string Replaces the Cursor-fg-derived cursor-text; emitted even when the highlight lacks one.
---@field selection_background? string Replaces the Visual-bg-derived selection-background; emitted even when the highlight lacks one.
---@field selection_foreground? string Replaces the Visual-fg-derived selection-foreground; emitted even when the highlight lacks one.
---@field palette? table<integer, string> Per-slot ANSI palette substitutions, keyed 0..15. Emitted as a partial palette when the scheme owns none.

---@class GhosttyMirrorThemeOverride
---@field accent? string Replaces the accent_hl-derived accent ("#rgb" or "#rrggbb").
---@field divider? string Replaces the divider_hl-derived pane border color ("#rgb" or "#rrggbb").
---@field bar? string Sets the status bar color directly, bypassing the blend ("#rgb" or "#rrggbb"). Wins over bar_blend.
---@field bar_blend? number Replaces tmux.bar_blend for this theme only, 0..1. Ignored when bar is set.

---@class GhosttyMirrorTmuxConfig
---@field enabled? boolean Mirror the colorscheme into tmux's statusline on :colorscheme. Defaults to false (opt-in).
---@field themes_dir? string Directory tmux theme files live in / are cached to. No quotes, backslashes or newlines (it lands inside the pointer's quoted source-file line); setup() errors otherwise. Defaults to ~/.config/tmux/themes.
---@field theme_file? string Pointer file tmux sources; the plugin writes `source-file <themes_dir>/<name>.conf` here. No quotes, backslashes or newlines; setup() errors otherwise. Defaults to ~/.config/tmux/theme-current.conf.
---@field generate? boolean Generate a tmux theme from live highlights when no hand-made file exists. Defaults to true.
---@field reload_command? string[]|nil Command to apply the theme to the running tmux server. nil uses `tmux source-file <theme_file>`.
---@field bar_blend? number How far the status bar blends from Normal's background toward the accent, 0..1 (keeps it in-hue rather than greying toward white). Defaults to 0.22.
---@field accent_hl? string Highlight group whose fg is the bright accent (selected window, active divider, status-right). Sourcing it from a highlight lets the accent harmonize with each scheme's own hue. Defaults to "Type".
---@field divider_hl? string Highlight group whose fg colors the inactive pane border. Defaults to "WinSeparator".
---@field overrides? table<GhosttyMirrorThemeName, GhosttyMirrorThemeOverride> Per-theme tweaks merged into generation, keyed by resolved theme name (the light variant keys separately, e.g. "cyberdream-light"). Defaults to {}.

---@type GhosttyMirrorConfig
local defaults = {
	themes_dir = vim.fn.expand("~/.config/ghostty/themes"),
	theme_file = vim.fn.expand("~/.config/ghostty/theme-current"),
	light_variant_suffix = "-light",
	generate = true,
	reload_command = { "pkill", "-SIGUSR2", "ghostty" },
	debounce_ms = 150,
	overrides = {},
	manage_background = false,
	sync_on_startup = false,
	sync_on_focus = false,
	tmux = {
		enabled = false,
		themes_dir = vim.fn.expand("~/.config/tmux/themes"),
		theme_file = vim.fn.expand("~/.config/tmux/theme-current.conf"),
		generate = true,
		reload_command = nil,
		bar_blend = 0.22,
		accent_hl = "Type",
		divider_hl = "WinSeparator",
		overrides = {},
	},
}

---@type GhosttyMirrorConfig
M.config = vim.deepcopy(defaults)

-- Header on every generated theme file. Marks a file as plugin-owned so we can
-- safely delete it on cache clear without touching hand-made themes.
local generated_marker = "# Generated by ghostty-mirror.nvim"

-- The character class for anything that becomes (part of) a theme file name:
-- word chars, dot, underscore, dash. Shared by the name guard, the suffix
-- guards and setup's suffix validation so they can't drift apart.
local safe_name_pattern = "^[%w._%-]+$"

---Whether a colorscheme name is safe to use as a theme file name and inside
---the Ghostty/tmux pointer files. The name flows into filesystem paths, a
---Ghostty config line and a tmux `source-file` command, so anything beyond
---word chars, dot, underscore and dash (path separators, quotes, newlines)
---is refused — fail silently, never wrongly. The bare dot names are refused
---too: `themes_dir .. "/.."` is a directory, not a theme.
---@param name string
---@return boolean
local function valid_name(name) return name:match(safe_name_pattern) ~= nil and name ~= "." and name ~= ".." end

---Write lines to a path, refusing to write through a symlink: a pre-planted
---link would silently redirect a plugin write into an arbitrary file. A
---check-then-write would leave a window for a racer to swap a link in
---(TOCTOU), and luv exposes no O_NOFOLLOW, so refuse by proof instead: open
---without truncating, then require the opened fd and the path to be the same
---regular file before a byte is written — a racing link lands on either the
---link itself (lstat) or a foreign inode (fstat) and is refused. O_NONBLOCK
---keeps a planted FIFO from hanging the open; it's a no-op for regular files.
---The open is two-step — plain first, O_CREAT|O_EXCL only on a missing path —
---because O_CREAT alone follows a dangling link and creates its target (the
---proof then refuses the write, but the empty file already landed); O_EXCL
---never follows a link, failing EEXIST even on a dangling one.
---Returns whether the write happened — fail silently, never wrongly.
---@param lines string[]
---@param path string
---@return boolean
local function write_no_symlink(lines, path)
	local c = vim.uv.constants
	local fd = vim.uv.fs_open(path, bit.bor(c.O_WRONLY, c.O_NONBLOCK), 438) -- 0666, masked by umask like writefile
	if not fd then fd = vim.uv.fs_open(path, bit.bor(c.O_WRONLY, c.O_CREAT, c.O_EXCL, c.O_NONBLOCK), 438) end
	if not fd then return false end
	local fst = vim.uv.fs_fstat(fd)
	local lst = vim.uv.fs_lstat(path)
	local same_file = fst ~= nil
		and lst ~= nil
		and fst.type == "file"
		and lst.type == "file"
		and fst.ino == lst.ino
		and fst.dev == lst.dev
	if not same_file then
		vim.uv.fs_close(fd)
		return false
	end
	local data = table.concat(lines, "\n") .. "\n"
	local ok = vim.uv.fs_ftruncate(fd, 0) ~= nil and vim.uv.fs_write(fd, data) == #data
	vim.uv.fs_close(fd)
	return ok
end

-- Byte ceiling on any plugin read. The files read are pointer files and theme
-- headers (a few hundred bytes), so anything past this is not ours to parse —
-- it also bounds what a planted file can make the plugin pull into memory.
local read_cap = 16384

---Read the first `count` lines of a file (the capped head when count is nil),
---tolerating it vanishing or turning unreadable between an fs_stat and the
---read (concurrent cache clear, another instance): an unreadable file reads
---as empty rather than throwing. Reads are guarded like writes are: the paths
---are writable by any process, so O_NONBLOCK keeps a planted FIFO from
---hanging the open, the fstat type check refuses special files (a /dev/zero
---link reads unboundedly), and read_cap bounds the pull.
---@param path string
---@param count? integer
---@return string[]
local function read_head(path, count)
	local c = vim.uv.constants
	local fd = vim.uv.fs_open(path, bit.bor(c.O_RDONLY, c.O_NONBLOCK), 0)
	if not fd then return {} end
	local fst = vim.uv.fs_fstat(fd)
	local data = fst ~= nil and fst.type == "file" and vim.uv.fs_read(fd, read_cap, 0) or nil
	vim.uv.fs_close(fd)
	if not data then return {} end
	local lines = vim.split(data, "\n")
	if lines[#lines] == "" then table.remove(lines) end -- readfile-style: no phantom line after a trailing newline
	return count and vim.list_slice(lines, 1, count) or lines
end

---Whether a theme file is plugin-generated (its first line is the marker).
---@param path string
---@return boolean
local function is_generated(path)
	local first = read_head(path, 1)[1]
	return first ~= nil and vim.startswith(first, generated_marker)
end

---Convert a 24-bit color integer (as returned by nvim_get_hl) to "#rrggbb".
---@param n integer|nil
---@return string|nil
local function hex(n)
	if type(n) ~= "number" then return nil end
	return string.format("#%06x", n)
end

---Resolve a highlight group to its effective fg/bg, following links.
---@param name string
---@return table
local function hl(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end

---Channels of a "#rrggbb" color.
---@param color string
---@return integer, integer, integer
local function rgb(color)
	return tonumber(color:sub(2, 3), 16), tonumber(color:sub(4, 5), 16), tonumber(color:sub(6, 7), 16)
end

---Perceived luminance of a "#rrggbb" color, 0 (black) .. 1 (white).
---@param color string
---@return number
local function luminance(color)
	local r, g, b = rgb(color)
	return (0.299 * r + 0.587 * g + 0.114 * b) / 255
end

---Blend color `a` toward color `b` by t (0..1): 0 returns `a`, 1 returns `b`.
---@param a string # "#rrggbb"
---@param b string # "#rrggbb"
---@param t number
---@return string
local function blend(a, b, t)
	local ar, ag, ab = rgb(a)
	local br, bg, bb = rgb(b)
	-- Clamp to the byte range: an out-of-range t would otherwise extrapolate
	-- past two hex digits per channel and emit a color nothing can parse.
	local function mix(x, y) return math.min(255, math.max(0, math.floor(x + (y - x) * t + 0.5))) end
	return string.format("#%02x%02x%02x", mix(ar, br), mix(ag, bg), mix(ab, bb))
end

---Normalize a user-supplied color to lowercase "#rrggbb": expands "#rgb"
---shorthand, returns nil for anything else so bad values drop silently.
---@param color any
---@return string|nil
local function normalize_color(color)
	if type(color) ~= "string" then return nil end
	color = color:lower()
	local r, g, b = color:match("^#(%x)(%x)(%x)$")
	if r then return "#" .. r .. r .. g .. g .. b .. b end
	return color:match("^#%x%x%x%x%x%x$")
end

---Whether a value is a usable blend amount: a number in 0..1. Anything else
---would extrapolate channels past the byte range and emit a malformed color.
---@param v any
---@return boolean
local function valid_blend(v) return type(v) == "number" and v >= 0 and v <= 1 end

---Whether a value is a usable palette slot index: an integer in 0..15.
---@param slot any
---@return boolean
local function valid_slot(slot) return type(slot) == "number" and slot >= 0 and slot <= 15 and slot % 1 == 0 end

---Return whichever of two candidates reads better on `color`: the lighter one
---on a dark color, the darker one on a light color. Picks by actual luminance
---(not by assuming which candidate is light), so it's correct on light themes
---where Normal's fg is the dark one.
---@param color string
---@param x string
---@param y string
---@return string
local function readable_on(color, x, y)
	local lighter, darker = x, y
	if luminance(y) > luminance(x) then
		lighter, darker = y, x
	end
	return luminance(color) < 0.5 and lighter or darker
end

---Snapshot the live terminal palette (g:terminal_color_0..15). Slots are
---normalized to clean "#rrggbb" — these values are concatenated into a file
---Ghostty parses, so anything else (a newline would smuggle in an arbitrary
---directive) becomes nil and the palette drops at the completeness gate.
---@return table<integer, string|nil>
local function snapshot_palette()
	local p = {}
	for i = 0, 15 do
		p[i] = normalize_color(vim.g["terminal_color_" .. i])
	end
	return p
end

---Whether two palette snapshots hold identical values across all 16 slots.
---@param a table<integer, string|nil>
---@param b table<integer, string|nil>
---@return boolean
local function palettes_equal(a, b)
	for i = 0, 15 do
		if a[i] ~= b[i] then return false end
	end
	return true
end

---Whether a palette snapshot has a (normalized) color in all 16 slots.
---@param p table<integer, string|nil>
---@return boolean
local function palette_complete(p)
	for i = 0, 15 do
		if p[i] == nil then return false end
	end
	return true
end

-- g:terminal_color_* is global and sticky: it survives :colorscheme changes,
-- so a scheme that defines no palette of its own inherits whatever the previous
-- scheme left behind. We snapshot it on ColorSchemePre and only trust it when
-- the new scheme actually changed it, so we never mirror a palette that doesn't
-- belong to the current colorscheme.
local prev_palette
local palette_owned = true

-- Pending debounced push; a colorscheme picker's live preview fires a
-- ColorScheme per previewed scheme, so we coalesce them and only mirror once
-- the scheme settles (see config.debounce_ms).
local push_timer

-- The colorscheme name from the last ColorScheme event's `match`. This is the
-- name as loaded (`cyberdream-light`), which can differ from `g:colors_name`
-- (some schemes, e.g. cyberdream, set it to a base name like `cyberdream` for
-- every variant). The force commands prefer this so they mirror the variant
-- actually on screen.
local last_scheme

---Cancel the pending debounced push, if any.
local function cancel_pending_push()
	if push_timer then
		push_timer:stop()
		push_timer:close()
		push_timer = nil
	end
end

---Mirror `colorscheme`, debounced by config.debounce_ms. A new change cancels
---the pending one, so only the settled scheme is pushed. 0 pushes immediately.
---@param colorscheme string
local function schedule_push(colorscheme)
	local delay = tonumber(M.config.debounce_ms) or 0
	if delay <= 0 then
		M.push(colorscheme)
		return
	end
	cancel_pending_push()
	local timer = vim.uv.new_timer()
	push_timer = timer
	timer:start(
		delay,
		0,
		vim.schedule_wrap(function()
			-- The cancel may have closed this timer while the callback sat in the
			-- schedule queue; a fired-but-cancelled push must stay cancelled.
			if timer:is_closing() then return end
			timer:close()
			if push_timer == timer then push_timer = nil end
			M.push(colorscheme)
		end)
	)
end

---The light variant suffix when it's safe to append to a validated name, nil
---when disabled ("" or false) or unsafe. setup() errors on an unsafe suffix,
---but M.config is plain data any code can mutate afterwards, and the suffix
---extends already-validated names into the same paths and pointer lines — so
---the character class is re-checked at the point of use, where an unsafe
---value reads as disabled.
---@return string|nil
local function safe_suffix()
	local suffix = M.config.light_variant_suffix
	if type(suffix) ~= "string" or not suffix:match(safe_name_pattern) then return nil end
	return suffix
end

---Name we'd write a generated theme under, honoring the light variant suffix
---when &background is "light" so light/dark caches stay separate.
---@param colorscheme string
---@return string
local function target_name(colorscheme)
	local suffix = safe_suffix()
	if suffix and vim.o.background == "light" then return colorscheme .. suffix end
	return colorscheme
end

---target_name's inverse: the base scheme name when `name` carries
---light_variant_suffix (and isn't just the bare suffix), nil otherwise.
---@param name string
---@return string|nil
local function light_base(name)
	local suffix = safe_suffix()
	if not (suffix and #name > #suffix and name:sub(-#suffix) == suffix) then return nil end
	return name:sub(1, -#suffix - 1)
end

---The normalized per-theme Ghostty overrides that actually take effect for a
---resolved theme name; invalid values are absent so generation falls back.
---@param name GhosttyMirrorThemeName
---@return GhosttyMirrorGhosttyOverride
local function ghostty_effective_overrides(name)
	local entry = M.config.overrides[name] or {}
	local o = {
		foreground = normalize_color(entry.foreground),
		cursor_color = normalize_color(entry.cursor_color),
		cursor_text = normalize_color(entry.cursor_text),
		selection_background = normalize_color(entry.selection_background),
		selection_foreground = normalize_color(entry.selection_foreground),
	}
	-- Bad slots/colors drop here so the valid rest still applies.
	if type(entry.palette) == "table" then
		local p = {}
		for slot, color in pairs(entry.palette) do
			local c = normalize_color(color)
			if valid_slot(slot) and c then p[slot] = c end
		end
		if next(p) then o.palette = p end
	end
	return o
end

---The normalized per-theme tmux overrides that actually take effect for a
---resolved theme name; invalid values are absent so generation falls back.
---@param name GhosttyMirrorThemeName
---@return GhosttyMirrorThemeOverride
local function tmux_effective_overrides(name)
	local entry = M.config.tmux.overrides[name] or {}
	return {
		accent = normalize_color(entry.accent),
		divider = normalize_color(entry.divider),
		bar = normalize_color(entry.bar),
		bar_blend = valid_blend(entry.bar_blend) and entry.bar_blend or nil,
	}
end

---Deterministic one-line stamp of an override set (sorted keys, normalized
---values), embedded in generated files so a config edit is detectable as a
---stale cache. nil when the set is empty.
---@param o table<string, string|number>
---@return string|nil
local function serialize_overrides(o)
	local keys = vim.tbl_keys(o)
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = ("%s=%s"):format(k, type(o[k]) == "number" and ("%g"):format(o[k]) or o[k])
	end
	if #parts == 0 then return nil end
	return "# overrides: " .. table.concat(parts, ",")
end

---Flatten an effective Ghostty override set for stamping: palette slots become
---palette<N> keys so the stamp stays a single line of scalar pairs.
---@param o GhosttyMirrorGhosttyOverride
---@return table<string, string>
local function flatten_palette(o)
	local flat = {}
	for k, v in pairs(o) do
		if k == "palette" then
			for slot, color in pairs(v) do
				flat["palette" .. slot] = color
			end
		else
			flat[k] = v
		end
	end
	return flat
end

---Build the lines of a Ghostty theme file from Neovim's *live* highlight state
---(the currently loaded colorscheme). Returns nil only when the colorscheme has
---no Normal fg/bg to anchor the theme. The highlight-derived colors (background,
---foreground, cursor, selection) are always the scheme's own, so they're mirrored
---unconditionally; the 16-color palette is only appended when this scheme owns a
---full one (see `palette_owned`), since terminal_color_* is global and sticky and
---a scheme that sets none of its own would otherwise mirror an inherited palette.
---@param colorscheme string
---@return string[]|nil
function M.generate(colorscheme)
	-- The name lands verbatim in the header line below; live callers guard via
	-- write_generated, but this is public API, so a newline-carrying name must
	-- die here too, not ride out in the returned lines.
	if not valid_name(colorscheme) then return nil end
	local normal = hl("Normal")
	local bg, fg = hex(normal.bg), hex(normal.fg)
	-- The anchor rule stands even under overrides: they tweak a theme the
	-- scheme can anchor, they don't bootstrap one from nothing.
	if not bg or not fg then return nil end

	local o = ghostty_effective_overrides(target_name(colorscheme))

	local lines = {
		generated_marker .. " from nvim colorscheme: " .. colorscheme,
		"background = " .. bg,
		"foreground = " .. (o.foreground or fg),
	}

	local cursor = hl("Cursor")
	local cc = o.cursor_color or hex(cursor.bg) or hex(cursor.fg)
	if cc then table.insert(lines, "cursor-color = " .. cc) end
	-- cursor-text is the glyph color under the block cursor; only meaningful when
	-- the cursor owns a bg (so cursor-color above came from bg, not from fg).
	local ct = o.cursor_text or (cursor.bg and hex(cursor.fg))
	if ct then table.insert(lines, "cursor-text = " .. ct) end

	local visual = hl("Visual")
	local sel = o.selection_background or hex(visual.bg)
	if sel then table.insert(lines, "selection-background = " .. sel) end
	local sel_fg = o.selection_foreground or hex(visual.fg)
	if sel_fg then table.insert(lines, "selection-foreground = " .. sel_fg) end

	local palette = snapshot_palette()
	if palette_owned and palette_complete(palette) then
		table.insert(lines, "")
		for i = 0, 15 do
			table.insert(lines, "palette = " .. i .. "=" .. ((o.palette and o.palette[i]) or palette[i]))
		end
	elseif o.palette then
		-- The scheme owns no palette to substitute into, but a slot override is
		-- explicit user intent: emit just those slots as a partial palette,
		-- outranking the inherited-palette caution above.
		table.insert(lines, "")
		for i = 0, 15 do
			if o.palette[i] then table.insert(lines, "palette = " .. i .. "=" .. o.palette[i]) end
		end
	end
	-- Stamp the overrides that shaped this file so resolve can tell a cache
	-- generated under a different config from a current one.
	local stamp = serialize_overrides(flatten_palette(o))
	if stamp then table.insert(lines, 2, stamp) end
	return lines
end

---Build the lines of a tmux theme file (a list of `set -g *-style` commands)
---from Neovim's live highlights. Returns nil only when Normal has no fg/bg to
---anchor the theme. The status bar is the background "a little lighter"; the
---bright accent (selected window + active pane border) comes from the scheme's
---ANSI slot when it owns a full palette, else from a syntax highlight group.
---@param colorscheme string
---@return string[]|nil
function M.generate_tmux(colorscheme)
	-- Same self-guard as generate: the header line is part of a file tmux
	-- executes, so a newline-carrying name must die here, not in some caller.
	if not valid_name(colorscheme) then return nil end
	local normal = hl("Normal")
	local bg, fg = hex(normal.bg), hex(normal.fg)
	if not bg or not fg then return nil end

	local cfg = M.config.tmux
	local o = tmux_effective_overrides(target_name(colorscheme))

	-- The accent can't be inferred from the background, so it's opinionated: a
	-- syntax highlight group's fg. Sourcing it from a highlight (not a fixed ANSI
	-- slot) lets it harmonize with the scheme's own hue — magenta-ish on a purple
	-- theme, blue on a blue one — instead of forcing one hue on every theme.
	local accent = o.accent or hex(hl(cfg.accent_hl).fg) or fg

	-- The status bar is the background nudged for contrast: on a dark theme,
	-- toward the accent (stays in-hue and saturated); on a light theme, toward
	-- the foreground, since a light bg blended toward a mid-tone accent barely
	-- moves and washes out. Selected-window text takes whichever of fg/bg reads
	-- on the accent.
	local light = luminance(bg) > 0.5
	-- An explicit bar override wins outright; bar_blend only shapes the blend.
	local bar = o.bar or blend(bg, light and fg or accent, o.bar_blend or cfg.bar_blend)
	local accent_fg = readable_on(accent, fg, bg)
	local divider = o.divider or hex(hl(cfg.divider_hl).fg) or accent

	local bar_pair = ("bg=%s,fg=%s"):format(bar, fg)
	local accent_pair = ("bg=%s,fg=%s"):format(accent, accent_fg)
	-- Style every base segment (incl. status-left, which tmux leaves at the
	-- theme default otherwise) with the bar color so the bar reads as one piece.
	-- On a light theme the accent appears only on the current window; on a dark
	-- theme status-right stays an accent pill.
	local right_pair = light and bar_pair or accent_pair

	local lines = {
		generated_marker .. " from nvim colorscheme: " .. colorscheme,
		('set -g status-style "%s"'):format(bar_pair),
		('set -g status-left-style "%s"'):format(bar_pair),
		('set -g status-right-style "%s"'):format(right_pair),
		('set -g window-status-style "%s"'):format(bar_pair),
		('set -g window-status-current-style "%s"'):format(accent_pair),
		('set -g pane-active-border-style "fg=%s"'):format(accent),
		('set -g pane-border-style "fg=%s"'):format(divider),
		('set -g message-style "%s"'):format(bar_pair),
		('set -g message-command-style "%s"'):format(bar_pair),
		('set -g mode-style "%s"'):format(accent_pair),
		('set -g clock-mode-colour "%s"'):format(accent),
	}
	-- Stamp the overrides that shaped this file so resolve_tmux can tell a
	-- cache generated under a different config from a current one.
	local stamp = serialize_overrides(o)
	if stamp then table.insert(lines, 2, stamp) end
	return lines
end

---Generate a theme from live highlights and write it to themes_dir.
---@param colorscheme string
---@return string|nil # the theme name written, or nil if generation wasn't possible
function M.write_generated(colorscheme)
	-- Live callers pre-check, but this is public API: the name becomes a path
	-- under themes_dir, so it must hold its own guard.
	if not valid_name(colorscheme) then return nil end
	local lines = M.generate(colorscheme)
	if not lines then return nil end
	local name = target_name(colorscheme)
	vim.fn.mkdir(M.config.themes_dir, "p")
	if not write_no_symlink(lines, M.config.themes_dir .. "/" .. name) then return nil end
	return name
end

---Generate a tmux theme from live highlights and write it to tmux.themes_dir as
---`<name>.conf`.
---@param colorscheme string
---@return string|nil # the theme name written, or nil if generation wasn't possible
function M.write_tmux_generated(colorscheme)
	-- Same self-guard as write_generated: public API, name becomes a path.
	if not valid_name(colorscheme) then return nil end
	local lines = M.generate_tmux(colorscheme)
	if not lines then return nil end
	local name = target_name(colorscheme)
	vim.fn.mkdir(M.config.tmux.themes_dir, "p")
	if not write_no_symlink(lines, M.config.tmux.themes_dir .. "/" .. name .. ".conf") then return nil end
	return name
end

---Whether a theme file is still the one we'd generate today: hand-made files
---are always current (the user owns them), a generated file is current only
---when its override stamp matches the one the configured overrides produce.
---@param path string
---@param expected_stamp string|nil
---@return boolean
local function cache_current(path, expected_stamp)
	if not is_generated(path) then return true end
	local second = read_head(path, 2)[2]
	local stamp = second ~= nil and vim.startswith(second, "# overrides:") and second or nil
	return stamp == expected_stamp
end

---The stamp the Ghostty overrides now configured produce for a theme name.
---@param name GhosttyMirrorThemeName
---@return string|nil
local function ghostty_stamp(name) return serialize_overrides(flatten_palette(ghostty_effective_overrides(name))) end

---The stamp the tmux overrides now configured produce for a theme name.
---@param name GhosttyMirrorThemeName
---@return string|nil
local function tmux_stamp(name) return serialize_overrides(tmux_effective_overrides(name)) end

---Resolve the tmux theme name for a colorscheme. Same precedence as `resolve`:
---a hand-made `<name>.conf` wins (honoring the light variant suffix), otherwise
---one is generated from live highlights and cached. A generated cache whose
---override stamp no longer matches the config is regenerated, so override
---edits take effect on the next push.
---@param colorscheme string
---@return string|nil # resolved theme name, nil when nothing resolves
---@return boolean|nil # true when the theme file was (re)generated by this call
function M.resolve_tmux(colorscheme)
	if not valid_name(colorscheme) then return nil end
	local cfg = M.config.tmux
	local suffix = safe_suffix()
	local light = suffix ~= nil and vim.o.background == "light"
	-- A stale cache only loses to regeneration when regenerating is possible.
	local function usable(path, name) return cache_current(path, tmux_stamp(name)) or not cfg.generate end
	if light then
		local variant = cfg.themes_dir .. "/" .. colorscheme .. suffix .. ".conf"
		if vim.uv.fs_stat(variant) and usable(variant, colorscheme .. suffix) then return colorscheme .. suffix end
	end
	-- Same as `resolve`: a generated bare .conf was built for dark, so don't
	-- mirror it under a light colorscheme — regenerate the light variant instead.
	local bare = cfg.themes_dir .. "/" .. colorscheme .. ".conf"
	if vim.uv.fs_stat(bare) and not (light and is_generated(bare)) and usable(bare, colorscheme) then
		return colorscheme
	end
	if cfg.generate then
		local name = M.write_tmux_generated(colorscheme)
		return name, name ~= nil
	end
	return nil
end

---Resolve the Ghostty theme name to write for a given Neovim colorscheme.
---Precedence: a hand-made/cached file wins (honoring the light variant suffix
---when &background is "light"); otherwise, if `generate` is enabled, a theme is
---built on the fly from live highlights and cached to themes_dir. A generated
---cache whose override stamp no longer matches the config is regenerated, so
---override edits take effect on the next push.
---@param colorscheme string
---@return string|nil # nil if no file exists and generation isn't possible
---@return boolean|nil # true when the theme file was (re)generated by this call
function M.resolve(colorscheme)
	if not valid_name(colorscheme) then return nil end
	local cfg = M.config
	local suffix = safe_suffix()
	local light = suffix ~= nil and vim.o.background == "light"
	-- A stale cache only loses to regeneration when regenerating is possible.
	local function usable(path, name) return cache_current(path, ghostty_stamp(name)) or not cfg.generate end
	if light then
		local variant = cfg.themes_dir .. "/" .. colorscheme .. suffix
		if vim.uv.fs_stat(variant) and usable(variant, colorscheme .. suffix) then return colorscheme .. suffix end
	end
	-- The bare <name> file is a valid fallback only when it's hand-made. A
	-- *generated* bare file was built for a dark background (Normal and
	-- terminal_color_* flip with &background), so reusing it in light mode would
	-- mirror the dark theme under a light colorscheme. Skip it and regenerate the
	-- light variant instead.
	local bare = cfg.themes_dir .. "/" .. colorscheme
	if vim.uv.fs_stat(bare) and not (light and is_generated(bare)) and usable(bare, colorscheme) then
		return colorscheme
	end
	if cfg.generate then
		local name = M.write_generated(colorscheme)
		return name, name ~= nil
	end
	return nil
end

---Write the resolved theme to the theme file and signal Ghostty to reload.
---@param colorscheme string
---@param opts? { force?: boolean } # force regenerates from live highlights, ignoring any existing file
---@return string|nil # the theme name written, or nil when nothing was written
function M.push(colorscheme, opts)
	-- No scheme to mirror (e.g. an aborted colorscheme load leaves colors_name
	-- nil): no-op rather than writing a bogus `theme =` line Ghostty can't load.
	if not colorscheme or not valid_name(colorscheme) then return end
	local name, regenerated
	if opts and opts.force then
		-- An explicit force trusts whatever palette is live right now.
		palette_owned = true
		name = M.write_generated(colorscheme)
	else
		name, regenerated = M.resolve(colorscheme)
	end
	if not name then return end
	-- Skip the rewrite + reload when Ghostty already points at this exact theme:
	-- SIGUSR2 reloads *every* Ghostty window, so spurious reloads (idempotent
	-- :colorscheme, a background re-apply cascade) aren't free. Safe because the
	-- non-force path only regenerates a stale-stamped cache, so the file Ghostty
	-- already loaded is byte-identical unless `regenerated` says otherwise. A
	-- cache regenerated under an unchanged pointer still reloads — the file
	-- content changed. Force always rewrites and reloads.
	if (opts and opts.force) or regenerated or M.read_current() ~= name then
		if write_no_symlink({ "theme = " .. name }, M.config.theme_file) then
			vim.system(M.config.reload_command, { detach = true })
		end
	end
	if M.config.tmux.enabled then M.push_tmux(colorscheme, opts) end
	return name
end

---The pointer line tmux sources, or nil when tmux.themes_dir can't sit inside
---the quoted source-file argument. setup() refuses an unsafe dir, but this
---line is what tmux executes and M.config is plain data any code can mutate
---after setup — so the quoting-escape check repeats at the sink.
---@param name string
---@return string|nil
local function tmux_pointer_line(name)
	local dir = M.config.tmux.themes_dir
	if type(dir) ~= "string" or dir:match('["\n\\]') then return nil end
	return 'source-file "' .. dir .. "/" .. name .. '.conf"'
end

---Resolve the tmux theme for a colorscheme, point tmux.theme_file at it, and
---tell the running tmux server to source it. No-op (no reload) when nothing
---resolves. Fails silently if no tmux server is running.
---@param colorscheme string
---@param opts? { force?: boolean }
---@return string|nil # the theme name written, or nil when nothing was written
function M.push_tmux(colorscheme, opts)
	if not colorscheme or not valid_name(colorscheme) then return end
	local cfg = M.config.tmux
	local name, regenerated
	if opts and opts.force then
		palette_owned = true
		name = M.write_tmux_generated(colorscheme)
	else
		name, regenerated = M.resolve_tmux(colorscheme)
	end
	if not name then return end
	-- Same idempotence as M.push: skip the source + reload when tmux already
	-- sources this exact theme (force always re-sources). A cache regenerated
	-- under an unchanged pointer still reloads — the file content changed.
	local line = tmux_pointer_line(name)
	if not line then return end
	local current = read_head(cfg.theme_file, 1)[1]
	if (opts and opts.force) or regenerated or current ~= line then
		if write_no_symlink({ line }, cfg.theme_file) then
			vim.system(cfg.reload_command or { "tmux", "source-file", cfg.theme_file }, { detach = true })
		end
	end
	return name
end

---Delete every generated file (first line is the generated marker) from a dir,
---leaving hand-made files untouched. Missing dirs are skipped. The marker
---check and the delete are two separate path lookups, so a racer swapping the
---file between them could lose a non-generated file. Accepted: luv exposes no
---unlinkat, so the window can only be narrowed, never closed, and the blast
---radius stays confined to the themes dirs (the vim.fs.dir type == "file"
---gate already excludes symlinks).
---@param dir string
---@return string[]
local function clear_generated_in(dir)
	local cleared = {}
	if not (dir and vim.uv.fs_stat(dir)) then return cleared end
	for name, type in vim.fs.dir(dir) do
		if type == "file" and is_generated(dir .. "/" .. name) then
			vim.fn.delete(dir .. "/" .. name)
			table.insert(cleared, name)
		end
	end
	return cleared
end

---Delete every generated theme file from themes_dir (and the tmux themes_dir
---when tmux mirroring is enabled), leaving hand-made files untouched. A file is
---plugin-owned when its first line is the generated marker, so stale caches can
---be cleared without risking the user's own themes.
---@return string[] # names of the files deleted
function M.clear_cache()
	local cleared = clear_generated_in(M.config.themes_dir)
	if M.config.tmux.enabled then vim.list_extend(cleared, clear_generated_in(M.config.tmux.themes_dir)) end
	return cleared
end

---Read the theme name currently set in Ghostty's theme-current file. Returns
---only names that pass valid_name: theme_file is writable by any process, and
---callers feed the name to :colorscheme (which resolves it against the
---runtimepath glob), so a planted `../`-style name must die here, not execute.
---@return string|nil
function M.read_current()
	for _, line in ipairs(read_head(M.config.theme_file)) do
		local name = line:match("theme%s*=%s*(%S+)")
		if name then return valid_name(name) and name or nil end
	end
	return nil
end

---Apply a theme name read from theme_file as a colorscheme. A generated light
---variant carries light_variant_suffix without being a colorscheme of its own
---(push writes "scintilla-sapphire-light" for scintilla-sapphire under a light
---background), so when the name doesn't load as-is, retry the base scheme
---under &background = "light" — set before the load so the scheme adapts as
---it applies. The full name is tried first: some variants (cyberdream-light)
---are real colorschemes.
---@param theme string
---@return boolean # whether a colorscheme was applied
local function apply_pulled(theme)
	if pcall(vim.cmd.colorscheme, theme) then return true end
	local base = light_base(theme)
	if not base then return false end
	local prev = vim.o.background
	vim.o.background = "light"
	if pcall(vim.cmd.colorscheme, base) then return true end
	vim.o.background = prev
	return false
end

---Apply the colorscheme stored in Ghostty's theme-current file to this Neovim
---instance. Used to pull the active theme into other nvim instances. Warns
---(rather than erroring) when the file is unreadable or names a colorscheme
---this instance doesn't have installed.
function M.pull()
	local theme = M.read_current()
	if not theme then
		vim.notify("ghostty-mirror: could not read theme from " .. M.config.theme_file, vim.log.levels.WARN)
		return
	end
	if not apply_pulled(theme) then
		vim.notify(
			('ghostty-mirror: colorscheme "%s" (named in %s) is not installed'):format(theme, M.config.theme_file),
			vim.log.levels.WARN
		)
	end
end

---The colorscheme name to act on for the force commands: the last settled
---ColorScheme `match` if one has fired, else `g:colors_name`. Prefers the
---event match because some schemes set `g:colors_name` to a base name shared
---across variants, which would mirror the wrong file.
---@return string
function M.current_scheme() return last_scheme or vim.g.colors_name or "" end

-- Expected type per config field; "string|false" admits the disable sentinel.
-- Hand-rolled (not vim.validate) to stay stable across the 0.11+ signature churn.
local config_types = {
	themes_dir = "string",
	theme_file = "string",
	light_variant_suffix = "string|false",
	generate = "boolean",
	reload_command = "table",
	debounce_ms = "number",
	overrides = "table",
	manage_background = "boolean",
	sync_on_startup = "boolean",
	sync_on_focus = "boolean",
	tmux = "table",
}

local tmux_config_types = {
	enabled = "boolean",
	themes_dir = "string",
	theme_file = "string",
	generate = "boolean",
	reload_command = "table|nil",
	bar_blend = "number",
	accent_hl = "string",
	divider_hl = "string",
	overrides = "table",
}

---Fail fast on a misshapen config (e.g. `tmux = true`) with a clear message,
---rather than erroring deep inside a later push.
---@param cfg table
---@param types table<string, string>
---@param prefix string
local function validate_config(cfg, types, prefix)
	for field, want in pairs(types) do
		local v = cfg[field]
		local ok = (want:find(type(v), 1, true) ~= nil) or (want:find("false", 1, true) and v == false)
		if not ok then
			error(("ghostty-mirror: config.%s%s must be %s, got %s"):format(prefix, field, want, type(v)), 0)
		end
	end
end

-- Recognized per-theme override params and their expected kind, per side.
local tmux_override_params = { accent = "color", divider = "color", bar = "color", bar_blend = "blend" }
local ghostty_override_params = {
	foreground = "color",
	cursor_color = "color",
	cursor_text = "color",
	selection_background = "color",
	selection_foreground = "color",
	palette = "palette",
}

---Warn (don't error) about override entries that can't take effect: a typo'd
---param or a malformed value would otherwise be ignored without a trace.
---@param overrides table<string, table>
---@param params table<string, string> # recognized params for this side
---@param side string # message prefix naming the side, e.g. "ghostty "
local function validate_overrides(overrides, params, side)
	-- Deferred: setup usually runs early in a user config, before a notifier
	-- plugin (nvim-notify, noice) has replaced vim.notify. Scheduling resolves
	-- vim.notify after startup, so warnings land in the user's notifier instead
	-- of the builtin echo and its blocking Press-ENTER prompt.
	local function warn(fmt, ...)
		local msg = "ghostty-mirror: " .. fmt:format(...)
		vim.schedule(function() vim.notify(msg, vim.log.levels.WARN) end)
	end
	-- Override keys are *resolved* names: the light variant carries the suffix
	-- without being a colorscheme of its own, so accept "<scheme><suffix>" too.
	local known = {}
	for _, scheme in ipairs(vim.fn.getcompletion("", "color")) do
		known[scheme] = true
	end
	for name, entry in pairs(overrides) do
		local base = light_base(name)
		if not (known[name] or (base and known[base])) then
			warn('%soverride for "%s" matches no installed colorscheme', side, name)
		end
		for param, value in pairs(entry) do
			local kind = params[param]
			if not kind then
				warn('unknown %soverride param "%s" for theme "%s"', side, param, name)
			elseif kind == "palette" and type(value) == "table" then
				for slot, color in pairs(value) do
					if not valid_slot(slot) then
						warn('invalid %soverride palette slot "%s" for theme "%s"', side, tostring(slot), name)
					elseif not normalize_color(color) then
						warn(
							'invalid %soverride palette[%d] value "%s" for theme "%s"',
							side,
							slot,
							tostring(color),
							name
						)
					end
				end
			else
				local invalid = (kind == "color" and not normalize_color(value))
					or (kind == "blend" and not valid_blend(value))
					or (kind == "palette" and type(value) ~= "table")
				if invalid then
					warn('invalid %soverride %s value "%s" for theme "%s"', side, param, tostring(value), name)
				end
			end
		end
	end
end

---@param opts? GhosttyMirrorConfig
function M.setup(opts)
	-- vim.uv and nvim_get_hl{ link = false } need 0.10; bail loudly rather than
	-- erroring obscurely on the first colorscheme change.
	if vim.fn.has("nvim-0.10") ~= 1 then
		vim.notify("ghostty-mirror requires Neovim 0.10+", vim.log.levels.ERROR)
		return
	end

	M.config = vim.tbl_deep_extend("force", defaults, opts or {})
	validate_config(M.config, config_types, "")
	validate_config(M.config.tmux, tmux_config_types, "tmux.")
	-- The suffix is appended to an already-validated colorscheme name, flowing
	-- into the same paths and pointer-file lines, so it must pass the same
	-- character class as the name itself ("" and false stay valid as disables).
	local suffix = M.config.light_variant_suffix
	if suffix and suffix ~= "" and not suffix:match(safe_name_pattern) then
		error(
			("ghostty-mirror: config.light_variant_suffix must contain only letters, digits, '.', '_' or '-', got %q"):format(
				suffix
			),
			0
		)
	end
	-- tmux.themes_dir is interpolated into the quoted `source-file "..."` line
	-- in a file tmux executes: a quote or newline escapes the quoting there,
	-- and tmux interprets backslash escapes inside the double quotes, so a
	-- backslash silently mangles the path.
	for _, field in ipairs({ "themes_dir", "theme_file" }) do
		if M.config.tmux[field]:match('["\n\\]') then
			error(("ghostty-mirror: config.tmux.%s must not contain quotes, backslashes or newlines"):format(field), 0)
		end
	end
	validate_overrides(M.config.overrides, ghostty_override_params, "ghostty ")
	validate_overrides(M.config.tmux.overrides, tmux_override_params, "tmux ")

	-- Re-setup is advertised as idempotent: a debounce armed under the old
	-- config must not fire a stale push under the new one.
	cancel_pending_push()

	local group = vim.api.nvim_create_augroup("ghostty-mirror", { clear = true })

	-- A debounce can also be pending at shutdown; don't push into a dying editor.
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = cancel_pending_push,
	})

	vim.api.nvim_create_autocmd("ColorSchemePre", {
		group = group,
		callback = function() prev_palette = snapshot_palette() end,
	})

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function(ev)
			last_scheme = ev.match
			local cur = snapshot_palette()
			palette_owned = prev_palette == nil or not palettes_equal(prev_palette, cur)
			schedule_push(ev.match)
		end,
	})

	if M.config.manage_background then
		-- Writing &background re-applies the current scheme (and re-fires these
		-- events), so guard every write to stop the two hooks looping.
		local adjusting = false
		local function set_background(want)
			if vim.o.background ~= want then
				adjusting = true
				vim.o.background = want
				adjusting = false
			end
		end

		-- Baseline to dark before a scheme loads, so &background-adaptive schemes
		-- (e.g. the built-in `default`) don't inherit a stale "light" left by a
		-- previous light scheme and render their washed variant.
		vim.api.nvim_create_autocmd("ColorSchemePre", {
			group = group,
			callback = function()
				if not adjusting then set_background("dark") end
			end,
		})

		-- After the scheme settles, sync &background to its actual Normal-bg
		-- luminance, so a scheme that renders light without setting &background
		-- itself (e.g. cyberdream-light) ends up light.
		vim.api.nvim_create_autocmd("ColorScheme", {
			group = group,
			callback = function()
				if adjusting then return end
				local bg = hex(hl("Normal").bg)
				if bg then set_background(luminance(bg) > 0.5 and "light" or "dark") end
			end,
		})
	end

	vim.api.nvim_create_user_command("ThemeFromGhostty", M.pull, {
		desc = "Apply the colorscheme currently set in Ghostty's theme-current file",
	})

	vim.api.nvim_create_user_command("ThemeToGhostty", function() M.push(M.current_scheme(), { force = true }) end, {
		desc = "Regenerate the current colorscheme's Ghostty theme from live highlights",
	})

	vim.api.nvim_create_user_command("ThemeToTmux", function() M.push_tmux(M.current_scheme(), { force = true }) end, {
		desc = "Regenerate the current colorscheme's tmux theme from live highlights",
	})

	vim.api.nvim_create_user_command("ThemeCacheClear", function()
		local cleared = M.clear_cache()
		vim.notify(
			("ghostty-mirror: cleared %d generated theme%s"):format(#cleared, #cleared == 1 and "" or "s"),
			vim.log.levels.INFO
		)
	end, {
		desc = "Delete every generated Ghostty/tmux theme file (hand-made themes are left untouched)",
	})

	if M.config.sync_on_startup then
		-- Apply the theme Ghostty currently points at so a freshly-opened nvim
		-- follows it. Deferred to VimEnter when setup runs during startup, since
		-- plugin colorschemes aren't loaded yet; run now if we're already past it.
		-- pcall keeps a missing/uninstalled colorscheme from erroring on launch.
		local function startup_sync()
			if M.read_current() then pcall(M.pull) end
		end
		if vim.v.vim_did_enter == 1 then
			startup_sync()
		else
			-- nested: the colorscheme this applies must re-fire the ColorScheme
			-- autocmd (events are suppressed inside non-nested callbacks), or the
			-- startup sync never pushes — e.g. an override edited before a restart
			-- would regenerate nothing until a manual :colorscheme.
			vim.api.nvim_create_autocmd(
				"VimEnter",
				{ group = group, once = true, nested = true, callback = startup_sync }
			)
		end
	end

	if M.config.sync_on_focus then
		-- Re-sync to whichever instance last wrote the theme when this window
		-- regains focus. Only re-apply when it actually differs from what we
		-- loaded — compared via target_name, since a light-variant pointer never
		-- equals the bare scheme name current_scheme reports and would otherwise
		-- re-apply on every focus. nested for the same reason as the startup
		-- sync: the applied colorscheme must re-fire ColorScheme so the mirror
		-- chain (push, stamp check, last_scheme) runs for the synced scheme too.
		vim.api.nvim_create_autocmd("FocusGained", {
			group = group,
			nested = true,
			callback = function()
				local theme = M.read_current()
				if theme and theme ~= target_name(M.current_scheme()) then apply_pulled(theme) end
			end,
		})
	end
end

return M
