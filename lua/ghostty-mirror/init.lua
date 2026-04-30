-- ghostty-mirror.nvim
-- Mirror Neovim's colorscheme into Ghostty so the terminal flips themes the
-- moment you change colorschemes in nvim.

local M = {}

---@class GhosttyMirrorConfig
---@field themes_dir string Directory Ghostty reads themes from. Defaults to ~/.config/ghostty/themes.
---@field theme_file string Path Ghostty reads the active theme from via config-file include. Defaults to ~/.config/ghostty/theme-current.
---@field keymap string|false Keymap that triggers :ThemeFromGhostty (pulls the theme from the file instead of writing to it). Set to false to skip the keymap.
---@field user_command string|false Name of the user command that pulls the theme from Ghostty's theme-current file. Set to false to skip the command.
---@field light_variant_suffix string Suffix used when looking for light-mode variant files (e.g. "cyberdream-light"). Set to "" or false to disable.
---@field reload_command string[] Command + args used to tell Ghostty to reload its config. Defaults to `pkill -SIGUSR2 ghostty`.

---@type GhosttyMirrorConfig
local defaults = {
	themes_dir = vim.fn.expand("~/.config/ghostty/themes"),
	theme_file = vim.fn.expand("~/.config/ghostty/theme-current"),
	keymap = "<M-t>",
	user_command = "ThemeFromGhostty",
	light_variant_suffix = "-light",
	reload_command = { "pkill", "-SIGUSR2", "ghostty" },
}

---@type GhosttyMirrorConfig
M.config = vim.deepcopy(defaults)

---Resolve the Ghostty theme name to write for a given Neovim colorscheme,
---honoring the light variant suffix when &background is "light".
---@param colorscheme string
---@return string|nil # nil if no matching theme file exists
function M.resolve(colorscheme)
	local cfg = M.config
	local name = colorscheme
	if
		cfg.light_variant_suffix
		and cfg.light_variant_suffix ~= ""
		and vim.o.background == "light"
		and vim.uv.fs_stat(cfg.themes_dir .. "/" .. name .. cfg.light_variant_suffix)
	then
		name = name .. cfg.light_variant_suffix
	end
	if vim.uv.fs_stat(cfg.themes_dir .. "/" .. name) == nil then
		return nil
	end
	return name
end

---Write the resolved theme to the theme file and signal Ghostty to reload.
---@param colorscheme string
function M.push(colorscheme)
	local name = M.resolve(colorscheme)
	if not name then return end
	vim.fn.writefile({ "theme = " .. name }, M.config.theme_file)
	vim.system(M.config.reload_command, { detach = true })
end

---Read the theme name currently set in Ghostty's theme-current file.
---@return string|nil
function M.read_current()
	if vim.fn.filereadable(M.config.theme_file) ~= 1 then return nil end
	local lines = vim.fn.readfile(M.config.theme_file)
	return lines[1] and lines[1]:match("theme%s*=%s*(%S+)") or nil
end

---Apply the colorscheme stored in Ghostty's theme-current file to this Neovim
---instance. Used to pull the active theme into other nvim instances.
function M.pull()
	local theme = M.read_current()
	if not theme then
		vim.notify(
			"ghostty-mirror: could not read theme from " .. M.config.theme_file,
			vim.log.levels.WARN
		)
		return
	end
	vim.cmd.colorscheme(theme)
end

---@param opts? GhosttyMirrorConfig
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", defaults, opts or {})

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("ghostty-mirror", { clear = true }),
		callback = function(ev) M.push(ev.match) end,
	})

	if M.config.user_command then
		vim.api.nvim_create_user_command(M.config.user_command, M.pull, {
			desc = "Apply the colorscheme currently set in Ghostty's theme-current file",
		})
	end

	if M.config.keymap then
		local cmd = M.config.user_command and ("<cmd>" .. M.config.user_command .. "<cr>")
			or function() M.pull() end
		vim.keymap.set("n", M.config.keymap, cmd, { desc = "Pull colorscheme from Ghostty" })
	end
end

return M
