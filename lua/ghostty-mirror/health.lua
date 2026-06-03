-- Health check for :checkhealth ghostty-mirror. Almost every failure mode of
-- this plugin is environmental (un-writable paths, a reload command that isn't
-- on $PATH, tmux not running), so surface those up front.

local M = {}

---Whether we can write to `path`: an existing writable file/dir, or a missing
---path whose parent directory is writable (so we'd create it on first push).
---@param path string|nil
---@return boolean
local function writable(path)
	if not path or path == "" then return false end
	if vim.fn.filewritable(path) ~= 0 then return true end -- 1 = file, 2 = dir
	return vim.fn.filewritable(vim.fn.fnamemodify(path, ":h")) == 2
end

---Candidate locations of Ghostty's main config, most specific first.
---Overridable so diagnostics() stays unit-testable.
---@return string[]
function M.ghostty_config_paths()
	local xdg = vim.env.XDG_CONFIG_HOME
	xdg = (xdg and xdg ~= "") and xdg or vim.fn.expand("~/.config")
	return {
		xdg .. "/ghostty/config",
		vim.fn.expand("~/Library/Application Support/com.mitchellh.ghostty/config"),
	}
end

---Absolute, ~-expanded form of a path for comparison.
---@param path string
---@return string
local function canonical(path)
	path = path:gsub("^~", vim.env.HOME or "~")
	return vim.fn.fnamemodify(path, ":p")
end

---Whether a Ghostty config file has a top-level `config-file` directive
---pointing at `theme_file`. Handles the optional-`?` prefix, quoted values,
---`~`, and paths relative to the config's own directory (Ghostty resolves
---them that way). Nested includes are not followed.
---@param config string
---@param theme_file string
---@return boolean
local function includes_theme_file(config, theme_file)
	local dir = vim.fn.fnamemodify(config, ":h")
	local want = canonical(theme_file)
	for _, line in ipairs(vim.fn.readfile(config)) do
		local value = line:match("^%s*config%-file%s*=%s*(.-)%s*$")
		if value then
			value = value:match('^"(.*)"$') or value
			value = value:gsub("^%?", "")
			if not value:match("^[~/]") then value = dir .. "/" .. value end
			if canonical(value) == want then return true end
		end
	end
	return false
end

---Best-effort: is a Ghostty process running? true/false, or nil when we can't
---tell (no `pgrep`). Overridable so diagnostics() stays unit-testable.
---@return boolean|nil
function M.ghostty_running()
	if vim.fn.executable("pgrep") ~= 1 then return nil end
	vim.fn.system({ "pgrep", "-x", "ghostty" })
	return vim.v.shell_error == 0
end

---Structured diagnostics, decoupled from vim.health so they're unit-testable.
---@return { status: "ok"|"warn"|"error"|"info", msg: string }[]
function M.diagnostics()
	local cfg = require("ghostty-mirror").config
	local d = {}
	local function add(status, msg) d[#d + 1] = { status = status, msg = msg } end

	if writable(cfg.themes_dir) then
		add("ok", "themes_dir writable: " .. cfg.themes_dir)
	else
		add("error", "themes_dir not writable: " .. tostring(cfg.themes_dir))
	end

	if writable(cfg.theme_file) then
		add("ok", "theme_file writable: " .. cfg.theme_file)
	else
		add("error", "theme_file not writable: " .. tostring(cfg.theme_file))
	end

	-- The most common setup miss: the plugin writes theme_file faithfully, but
	-- Ghostty never reads it because the main config lacks the include line.
	local wired, found = nil, nil
	for _, config in ipairs(M.ghostty_config_paths()) do
		if vim.fn.filereadable(config) == 1 then
			found = found or config
			if includes_theme_file(config, cfg.theme_file) then
				wired = config
				break
			end
		end
	end
	local include_line = "config-file = ?" .. cfg.theme_file
	if wired then
		add("ok", "theme_file included from " .. wired)
	elseif found then
		add("warn", ("theme_file is not included from %s; add (last): %s"):format(found, include_line))
	else
		add("warn", "no Ghostty config found; create one containing: " .. include_line)
	end

	local cmd = cfg.reload_command and cfg.reload_command[1]
	if cmd and vim.fn.executable(cmd) == 1 then
		add("ok", "reload command on PATH: " .. table.concat(cfg.reload_command, " "))
	else
		add("error", "reload command not executable: " .. tostring(cmd))
	end

	local running = M.ghostty_running()
	if running == nil then
		add("info", "could not check for a running Ghostty (pgrep unavailable)")
	elseif running then
		add("ok", "Ghostty process is running")
	else
		add("warn", "no running Ghostty found; reloads silently no-op until one starts")
	end

	if cfg.tmux and cfg.tmux.enabled then
		if writable(cfg.tmux.themes_dir) then
			add("ok", "tmux themes_dir writable: " .. cfg.tmux.themes_dir)
		else
			add("error", "tmux themes_dir not writable: " .. tostring(cfg.tmux.themes_dir))
		end
		if writable(cfg.tmux.theme_file) then
			add("ok", "tmux theme_file writable: " .. cfg.tmux.theme_file)
		else
			add("error", "tmux theme_file not writable: " .. tostring(cfg.tmux.theme_file))
		end
		if vim.fn.executable("tmux") == 1 then
			add("ok", "tmux found on PATH")
		else
			add("warn", "tmux mirroring is enabled but tmux is not on PATH")
		end
	else
		add("info", "tmux mirroring disabled (config.tmux.enabled = false)")
	end

	return d
end

---:checkhealth ghostty-mirror entry point.
function M.check()
	vim.health.start("ghostty-mirror")
	for _, e in ipairs(M.diagnostics()) do
		local report = vim.health[e.status] or vim.health.info
		report(e.msg)
	end
end

return M
