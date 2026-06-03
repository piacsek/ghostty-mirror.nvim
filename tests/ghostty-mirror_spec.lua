local function with_tmp_dir(fn)
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local ok, err = pcall(fn, dir)
	vim.fn.delete(dir, "rf")
	if not ok then error(err) end
end

---Reload the module fresh so each test gets a clean copy with default config.
local function fresh_require()
	package.loaded["ghostty-mirror"] = nil
	return require("ghostty-mirror")
end

---Stub vim.system to capture invocations and return immediately.
local function stub_system()
	local calls = {}
	local original = vim.system
	vim.system = function(cmd, opts) ---@diagnostic disable-line: duplicate-set-field
		table.insert(calls, { cmd = cmd, opts = opts })
		return { wait = function() return { code = 0 } end }
	end
	return calls, function() vim.system = original end
end

---Set a full terminal palette plus Normal/Cursor/Visual highlights so generation
---has everything it needs, and return after restoring the palette.
local function with_palette(fn)
	local saved = {}
	for i = 0, 15 do
		saved[i] = vim.g["terminal_color_" .. i]
		vim.g["terminal_color_" .. i] = string.format("#%02x0000", i)
	end
	vim.o.background = "dark"
	vim.api.nvim_set_hl(0, "Normal", { fg = 0xcdd6f4, bg = 0x1e1e2e })
	vim.api.nvim_set_hl(0, "Cursor", { bg = 0xf5e0dc })
	vim.api.nvim_set_hl(0, "Visual", { bg = 0x45475a })
	vim.api.nvim_set_hl(0, "Type", { fg = 0x89b4fa }) -- accent source for tmux generation
	local ok, err = pcall(fn)
	for i = 0, 15 do
		vim.g["terminal_color_" .. i] = saved[i]
	end
	if not ok then error(err) end
end

describe("ghostty-mirror", function()
	describe("resolve", function()
		it("returns the colorscheme name when a matching theme file exists", function()
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile({ "background = #000000" }, themes_dir .. "/foo")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir })
				assert.equals("foo", mirror.resolve("foo"))
			end)
		end)

		it("returns nil when no matching theme file exists and generation is off", function()
			with_tmp_dir(function(themes_dir)
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir, generate = false })
				assert.is_nil(mirror.resolve("nonexistent"))
			end)
		end)

		it("prefers <name>-light when background is light and the variant exists", function()
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile({ "" }, themes_dir .. "/foo")
				vim.fn.writefile({ "" }, themes_dir .. "/foo-light")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir })
				vim.o.background = "light"
				assert.equals("foo-light", mirror.resolve("foo"))
			end)
		end)

		it("uses the base name when background is light but no -light variant exists", function()
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile({ "" }, themes_dir .. "/foo")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir })
				vim.o.background = "light"
				assert.equals("foo", mirror.resolve("foo"))
			end)
		end)

		it("uses the base name when background is dark even if -light exists", function()
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile({ "" }, themes_dir .. "/foo")
				vim.fn.writefile({ "" }, themes_dir .. "/foo-light")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir })
				vim.o.background = "dark"
				assert.equals("foo", mirror.resolve("foo"))
			end)
		end)

		it("honors a custom light_variant_suffix", function()
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile({ "" }, themes_dir .. "/foo")
				vim.fn.writefile({ "" }, themes_dir .. "/foo_day")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir, light_variant_suffix = "_day" })
				vim.o.background = "light"
				assert.equals("foo_day", mirror.resolve("foo"))
			end)
		end)
	end)

	describe("push", function()
		it("writes 'theme = <name>' to theme_file and invokes the reload command", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")
				vim.fn.writefile({ "" }, themes_dir .. "/foo")

				local calls, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo", "reload" },
				})
				mirror.push("foo")
				restore()

				assert.same({ "theme = foo" }, vim.fn.readfile(theme_file))
				assert.equals(1, #calls)
				assert.same({ "echo", "reload" }, calls[1].cmd)
			end)
		end)

		it("also mirrors to tmux when tmux.enabled", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local g_themes, t_themes = dir .. "/g", dir .. "/t"
					vim.fn.mkdir(g_themes, "p")
					vim.fn.mkdir(t_themes, "p")
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({
						themes_dir = g_themes,
						theme_file = dir .. "/g-current",
						reload_command = { "echo", "ghostty" },
						tmux = {
							enabled = true,
							themes_dir = t_themes,
							theme_file = dir .. "/t-current.conf",
							reload_command = { "echo", "tmux" },
						},
					})
					mirror.push("mytheme")
					restore()

					assert.equals(1, vim.fn.filereadable(t_themes .. "/mytheme.conf"))
					assert.equals(2, #calls) -- both the ghostty and tmux reloads fired
				end)
			end)
		end)

		it("does not touch tmux when tmux.enabled is false", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local g_themes, t_themes = dir .. "/g", dir .. "/t"
					vim.fn.mkdir(g_themes, "p")
					vim.fn.mkdir(t_themes, "p")
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({
						themes_dir = g_themes,
						theme_file = dir .. "/g-current",
						reload_command = { "echo" },
						tmux = { themes_dir = t_themes, theme_file = dir .. "/t.conf" },
					})
					mirror.push("mytheme")
					restore()

					assert.equals(0, vim.fn.filereadable(t_themes .. "/mytheme.conf"))
					assert.equals(1, #calls) -- only the ghostty reload
				end)
			end)
		end)

		it("is a no-op when no theme file matches and generation is off", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")

				local calls, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir, theme_file = theme_file, generate = false })
				mirror.push("nonexistent")
				restore()

				assert.equals(0, vim.fn.filereadable(theme_file))
				assert.equals(0, #calls)
			end)
		end)
	end)

	describe("generate", function()
		it("builds background, foreground and a 16-color palette from live highlights", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({ generate = true })
				local lines = mirror.generate("mytheme")
				assert.is_not_nil(lines)
				local joined = table.concat(lines, "\n")
				assert.is_truthy(joined:find("background = #1e1e2e", 1, true))
				assert.is_truthy(joined:find("foreground = #cdd6f4", 1, true))
				assert.is_truthy(joined:find("cursor%-color = #f5e0dc"))
				assert.is_truthy(joined:find("selection%-background = #45475a"))
				assert.is_truthy(joined:find("palette = 0=#000000", 1, true))
				assert.is_truthy(joined:find("palette = 15=#0f0000", 1, true))
			end)
		end)

		it("omits the palette but still emits colors when the palette is incomplete", function()
			with_palette(function()
				vim.g.terminal_color_7 = nil
				local mirror = fresh_require()
				mirror.setup({ generate = true })
				local lines = mirror.generate("mytheme")
				assert.is_not_nil(lines)
				local joined = table.concat(lines, "\n")
				assert.is_truthy(joined:find("background = #1e1e2e", 1, true))
				assert.is_truthy(joined:find("cursor%-color = #f5e0dc"))
				assert.is_nil(joined:find("palette = ", 1, true))
			end)
		end)

		it("returns nil when the colorscheme has no Normal fg/bg to anchor the theme", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Normal", {})
				local mirror = fresh_require()
				mirror.setup({ generate = true })
				assert.is_nil(mirror.generate("mytheme"))
			end)
		end)

		it("resolve generates and caches a theme file when none exists", function()
			with_palette(function()
				with_tmp_dir(function(themes_dir)
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					assert.equals("mytheme", mirror.resolve("mytheme"))
					assert.equals(1, vim.fn.filereadable(themes_dir .. "/mytheme"))
				end)
			end)
		end)

		it("creates themes_dir when it does not exist before writing", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/nested/themes"
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					assert.equals("mytheme", mirror.resolve("mytheme"))
					assert.equals(1, vim.fn.filereadable(themes_dir .. "/mytheme"))
				end)
			end)
		end)

		it("prefers an existing hand-made file over generating", function()
			with_palette(function()
				with_tmp_dir(function(themes_dir)
					vim.fn.writefile({ "background = #abcdef" }, themes_dir .. "/mytheme")
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					assert.equals("mytheme", mirror.resolve("mytheme"))
					-- untouched: still the hand-made one line, not a generated file
					assert.same({ "background = #abcdef" }, vim.fn.readfile(themes_dir .. "/mytheme"))
				end)
			end)
		end)

		it("caches the light variant under the suffixed name when background is light", function()
			with_palette(function()
				with_tmp_dir(function(themes_dir)
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					vim.o.background = "light"
					assert.equals("mytheme-light", mirror.resolve("mytheme"))
					assert.equals(1, vim.fn.filereadable(themes_dir .. "/mytheme-light"))
					vim.o.background = "dark"
				end)
			end)
		end)

			it("regenerates a light variant rather than reusing a generated dark base in light mode", function()
				with_palette(function()
					with_tmp_dir(function(themes_dir)
						-- A generated (plugin-owned) dark cache left by a prior dark session.
						-- The new scheme flipped &background to light, so the stale dark base
						-- must not be mirrored under it; regenerate the light variant instead.
						vim.fn.writefile(
							{ "# Generated by ghostty-mirror.nvim from nvim colorscheme: foo", "background = #14161b" },
							themes_dir .. "/foo"
						)
						local mirror = fresh_require()
						mirror.setup({ themes_dir = themes_dir, generate = true })
						vim.o.background = "light"
						assert.equals("foo-light", mirror.resolve("foo"))
						assert.equals(1, vim.fn.filereadable(themes_dir .. "/foo-light"))
						vim.o.background = "dark"
					end)
				end)
			end)

			it("still reuses a hand-made base file in light mode (no -light variant)", function()
				with_palette(function()
					with_tmp_dir(function(themes_dir)
						-- Hand-made (no generated marker): the documented "base serves both" case.
						vim.fn.writefile({ "background = #abcdef" }, themes_dir .. "/foo")
						local mirror = fresh_require()
						mirror.setup({ themes_dir = themes_dir, generate = true })
						vim.o.background = "light"
						assert.equals("foo", mirror.resolve("foo"))
						assert.equals(0, vim.fn.filereadable(themes_dir .. "/foo-light"))
						vim.o.background = "dark"
					end)
				end)
			end)
	end)

	describe("generate_tmux", function()
		it("emits status, window and pane-border styles anchored on Normal", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true } })
				local lines = mirror.generate_tmux("mytheme")
				assert.is_not_nil(lines)
				local joined = table.concat(lines, "\n")
				assert.is_truthy(joined:find("set %-g status%-style"))
				assert.is_truthy(joined:find("set %-g window%-status%-current%-style"))
				assert.is_truthy(joined:find("set %-g pane%-active%-border%-style"))
				assert.is_truthy(joined:find("set %-g pane%-border%-style"))
			end)
		end)

		it("returns nil when the colorscheme has no Normal fg/bg", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Normal", {})
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true } })
				assert.is_nil(mirror.generate_tmux("mytheme"))
			end)
		end)

		it("sources the accent from the configured highlight group", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Special", { fg = 0xff5faf })
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true, accent_hl = "Special" } })
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				assert.is_truthy(joined:find('window%-status%-current%-style "bg=#ff5faf'))
				assert.is_truthy(joined:find('pane%-active%-border%-style "fg=#ff5faf'))
			end)
		end)

		it("styles status-right with the accent so accent-pill segments follow the theme", function()
			with_palette(function()
				-- Type (the accent source) is #89b4fa in with_palette; light -> dark fg
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true } })
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				assert.is_truthy(joined:find('set %-g status%-right%-style "bg=#89b4fa,fg=#1e1e2e'))
			end)
		end)

		it("styles status-left to match the bar so there's no unstyled default segment", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true } })
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				local bar_bg = joined:match('status%-style "bg=(#%x%x%x%x%x%x)')
				assert.is_truthy(joined:find('set -g status-left-style "bg=' .. bar_bg, 1, true))
			end)
		end)

		it("on a light background keeps the bar one color (accent only on the current window)", function()
			vim.o.background = "light"
			vim.api.nvim_set_hl(0, "Normal", { fg = 0x000000, bg = 0xe4e4e4 })
			vim.api.nvim_set_hl(0, "Type", { fg = 0x2e8b57 })
			local mirror = fresh_require()
			mirror.setup({ tmux = { enabled = true, bar_blend = 0.25 } })
			local joined = table.concat(mirror.generate_tmux("lighttheme"), "\n")
			local bar_bg = joined:match('status%-style "bg=(#%x%x%x%x%x%x)') -- #ababab
			-- status-left and status-right both match the bar — no accent pill on a light theme
			assert.is_truthy(joined:find('set -g status-left-style "bg=' .. bar_bg, 1, true))
			assert.is_truthy(joined:find('set -g status-right-style "bg=' .. bar_bg, 1, true))
			-- the current window is the only accent
			assert.is_truthy(joined:find('set -g window-status-current-style "bg=#2e8b57', 1, true))
			vim.o.background = "dark"
		end)

		it("blends the status bar background from Normal toward the accent", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Type", { fg = 0xff00ff }) -- bright magenta accent
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true, bar_blend = 0.25 } })
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				local bar = joined:match('status%-style "bg=(#%x%x%x%x%x%x)')
				-- Normal.bg #1e1e2e blended 25% toward #ff00ff
				assert.equals("#561762", bar)
			end)
		end)

		it("picks the accent foreground by contrast: light on a dark accent, dark on a light one", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Type", { fg = 0x222222 }) -- dark accent -> light fg (Normal.fg)
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true } })
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				assert.is_truthy(joined:find('window%-status%-current%-style "bg=#222222,fg=#cdd6f4'))

				vim.api.nvim_set_hl(0, "Type", { fg = 0xeeeeee }) -- light accent -> dark fg (Normal.bg)
				local joined2 = table.concat(mirror.generate_tmux("mytheme"), "\n")
				assert.is_truthy(joined2:find('window%-status%-current%-style "bg=#eeeeee,fg=#1e1e2e'))
			end)
		end)

		it("on a light background deepens the bar toward the foreground and keeps pill text legible", function()
			vim.o.background = "light"
			vim.api.nvim_set_hl(0, "Normal", { fg = 0x000000, bg = 0xe4e4e4 })
			vim.api.nvim_set_hl(0, "Type", { fg = 0x2e8b57 }) -- mid-tone accent
			local mirror = fresh_require()
			mirror.setup({ tmux = { enabled = true, bar_blend = 0.25 } })
			local joined = table.concat(mirror.generate_tmux("lighttheme"), "\n")
			-- bar deepens toward fg #000 (not toward the accent): blend(#e4e4e4,#000,0.25)
			assert.equals("#ababab", joined:match('status%-style "bg=(#%x%x%x%x%x%x)'))
			-- pill text is the lighter of fg/bg (legible on the mid accent), not the dark fg
			assert.is_truthy(joined:find('window%-status%-current%-style "bg=#2e8b57,fg=#e4e4e4'))
			vim.o.background = "dark"
		end)
	end)

	describe("resolve_tmux", function()
		it("generates and caches a <name>.conf when none exists", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = dir } })
					assert.equals("mytheme", mirror.resolve_tmux("mytheme"))
					assert.equals(1, vim.fn.filereadable(dir .. "/mytheme.conf"))
				end)
			end)
		end)

		it("prefers a hand-made .conf over generating", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					vim.fn.writefile({ 'set -g status-style "bg=#abcdef"' }, dir .. "/mytheme.conf")
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = dir } })
					assert.equals("mytheme", mirror.resolve_tmux("mytheme"))
					assert.same({ 'set -g status-style "bg=#abcdef"' }, vim.fn.readfile(dir .. "/mytheme.conf"))
				end)
			end)
		end)

		it("caches the light variant under <name>-light.conf when background is light", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = dir } })
					vim.o.background = "light"
					assert.equals("mytheme-light", mirror.resolve_tmux("mytheme"))
					assert.equals(1, vim.fn.filereadable(dir .. "/mytheme-light.conf"))
					vim.o.background = "dark"
				end)
			end)
		end)

			it("regenerates a light variant rather than reusing a generated dark base .conf in light mode", function()
				with_palette(function()
					with_tmp_dir(function(dir)
						vim.fn.writefile(
							{ "# Generated by ghostty-mirror.nvim from nvim colorscheme: foo", 'set -g status-style "bg=#14161b"' },
							dir .. "/foo.conf"
						)
						local mirror = fresh_require()
						mirror.setup({ tmux = { enabled = true, themes_dir = dir } })
						vim.o.background = "light"
						assert.equals("foo-light", mirror.resolve_tmux("foo"))
						assert.equals(1, vim.fn.filereadable(dir .. "/foo-light.conf"))
						vim.o.background = "dark"
					end)
				end)
			end)
	end)

	describe("push_tmux", function()
		it("writes a source-file pointer and invokes 'tmux source-file' by default", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/themes"
					local theme_file = dir .. "/theme-current.conf"
					vim.fn.mkdir(themes_dir, "p")
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = themes_dir, theme_file = theme_file } })
					mirror.push_tmux("mytheme")
					restore()

					assert.same({ 'source-file "' .. themes_dir .. '/mytheme.conf"' }, vim.fn.readfile(theme_file))
					assert.equals(1, #calls)
					assert.same({ "tmux", "source-file", theme_file }, calls[1].cmd)
				end)
			end)
		end)

		it("honors a custom tmux reload_command", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/themes"
					vim.fn.mkdir(themes_dir, "p")
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({
						tmux = {
							enabled = true,
							themes_dir = themes_dir,
							theme_file = dir .. "/tc.conf",
							reload_command = { "echo", "reloaded" },
						},
					})
					mirror.push_tmux("mytheme")
					restore()
					assert.same({ "echo", "reloaded" }, calls[1].cmd)
				end)
			end)
		end)
	end)

	describe("clear_cache", function()
		it("deletes generated theme files but leaves hand-made ones", function()
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile(
					{ "# Generated by ghostty-mirror.nvim from nvim colorscheme: gen", "background = #000000" },
					themes_dir .. "/gen"
				)
				vim.fn.writefile({ "background = #abcdef" }, themes_dir .. "/handmade")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir })

				local cleared = mirror.clear_cache()

				assert.equals(0, vim.fn.filereadable(themes_dir .. "/gen"))
				assert.equals(1, vim.fn.filereadable(themes_dir .. "/handmade"))
				assert.same({ "gen" }, cleared)
			end)
		end)

		it("also clears generated tmux theme files, leaving hand-made ones", function()
			with_tmp_dir(function(dir)
				local g, t = dir .. "/g", dir .. "/t"
				vim.fn.mkdir(g, "p")
				vim.fn.mkdir(t, "p")
				vim.fn.writefile(
					{ "# Generated by ghostty-mirror.nvim from nvim colorscheme: gen", 'set -g status-style "bg=#000000"' },
					t .. "/gen.conf"
				)
				vim.fn.writefile({ 'set -g status-style "bg=#abcdef"' }, t .. "/hand.conf")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = g, tmux = { enabled = true, themes_dir = t } })

				local cleared = mirror.clear_cache()

				assert.equals(0, vim.fn.filereadable(t .. "/gen.conf"))
				assert.equals(1, vim.fn.filereadable(t .. "/hand.conf"))
				assert.is_true(vim.tbl_contains(cleared, "gen.conf"))
			end)
		end)
	end)

	describe("read_current", function()
		it("parses 'theme = <name>' from theme_file", function()
			with_tmp_dir(function(dir)
				local theme_file = dir .. "/theme-current"
				vim.fn.writefile({ "theme = bar" }, theme_file)
				local mirror = fresh_require()
				mirror.setup({ theme_file = theme_file })
				assert.equals("bar", mirror.read_current())
			end)
		end)

		it("returns nil when the file is missing", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({ theme_file = dir .. "/missing" })
				assert.is_nil(mirror.read_current())
			end)
		end)

		it("returns nil when the file's content is malformed", function()
			with_tmp_dir(function(dir)
				local theme_file = dir .. "/theme-current"
				vim.fn.writefile({ "garbage" }, theme_file)
				local mirror = fresh_require()
				mirror.setup({ theme_file = theme_file })
				assert.is_nil(mirror.read_current())
			end)
		end)

		it("tolerates extra whitespace around '='", function()
			with_tmp_dir(function(dir)
				local theme_file = dir .. "/theme-current"
				vim.fn.writefile({ "theme   =   spaced" }, theme_file)
				local mirror = fresh_require()
				mirror.setup({ theme_file = theme_file })
				assert.equals("spaced", mirror.read_current())
			end)
		end)
	end)

	describe("setup", function()
		it("registers the ColorScheme autocmd in the ghostty-mirror augroup", function()
			local mirror = fresh_require()
			mirror.setup()
			local autocmds = vim.api.nvim_get_autocmds({
				event = "ColorScheme",
				group = "ghostty-mirror",
			})
			assert.is_true(#autocmds > 0)
		end)

		it("creates the ThemeFromGhostty command", function()
			local mirror = fresh_require()
			mirror.setup()
			assert.is_not_nil(vim.api.nvim_get_commands({})["ThemeFromGhostty"])
		end)

		it("creates the ThemeToGhostty command", function()
			local mirror = fresh_require()
			mirror.setup()
			assert.is_not_nil(vim.api.nvim_get_commands({})["ThemeToGhostty"])
		end)

		it("creates the ThemeToTmux command", function()
			local mirror = fresh_require()
			mirror.setup()
			assert.is_not_nil(vim.api.nvim_get_commands({})["ThemeToTmux"])
		end)

		it("creates the ThemeCacheClear command", function()
			local mirror = fresh_require()
			mirror.setup()
			assert.is_not_nil(vim.api.nvim_get_commands({})["ThemeCacheClear"])
		end)

		it("does not register any keymap (left to the user)", function()
			pcall(vim.keymap.del, "n", "<M-t>")
			local mirror = fresh_require()
			mirror.setup()
			local maps = vim.api.nvim_get_keymap("n")
			for _, m in ipairs(maps) do
				assert.are_not.equals("<M-t>", m.lhs)
			end
		end)
	end)

	describe("integration: ColorScheme autocmd", function()
		it("writes the theme file when :colorscheme fires for a known theme", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")
				-- Use a real bundled colorscheme so :colorscheme actually loads.
				vim.fn.writefile({ "" }, themes_dir .. "/elflord")

				local _, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo" },
					debounce_ms = 0,
				})
				vim.cmd.colorscheme("elflord")
				restore()

				assert.same({ "theme = elflord" }, vim.fn.readfile(theme_file))
			end)
		end)

		it("debounces rapid colorscheme changes into a single push", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")
				for _, n in ipairs({ "elflord", "habamax", "default" }) do
					vim.fn.writefile({ "" }, themes_dir .. "/" .. n)
				end

				local calls, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo" },
					debounce_ms = 40,
				})
				vim.cmd.colorscheme("elflord")
				vim.cmd.colorscheme("habamax")
				vim.cmd.colorscheme("default")
				assert.equals(0, #calls) -- nothing pushed synchronously while debouncing
				vim.wait(400, function() return #calls > 0 end)
				restore()

				assert.equals(1, #calls) -- the three rapid switches coalesced into one push
				assert.same({ "theme = default" }, vim.fn.readfile(theme_file))
			end)
		end)
	end)

	describe("integration: palette ownership", function()
		---Set a full terminal palette as if left behind by a previous colorscheme,
		---returning a function that restores the prior values.
		local function with_stale_palette()
			local saved = {}
			for i = 0, 15 do
				saved[i] = vim.g["terminal_color_" .. i]
				vim.g["terminal_color_" .. i] = string.format("#%02x0000", i)
			end
			return function()
				for i = 0, 15 do
					vim.g["terminal_color_" .. i] = saved[i]
				end
			end
		end

		it("mirrors colors without a palette when the colorscheme leaves the terminal palette unchanged", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")

				local restore_palette = with_stale_palette()
				local calls, restore_sys = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo" },
					debounce_ms = 0,
				})
				-- `default` sets a complete Normal but never touches terminal_color_*,
				-- so the palette stays exactly as the previous scheme left it. We still
				-- mirror its highlight-derived colors, just without a (stale) palette.
				vim.cmd.colorscheme("default")
				restore_sys()
				restore_palette()

				assert.same({ "theme = default" }, vim.fn.readfile(theme_file))
				local generated = table.concat(vim.fn.readfile(themes_dir .. "/default"), "\n")
				assert.is_truthy(generated:find("background = ", 1, true))
				assert.is_nil(generated:find("palette = ", 1, true))
				assert.equals(1, #calls)
			end)
		end)

		it("still generates when the colorscheme sets its own palette", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")

				local restore_palette = with_stale_palette()
				local calls, restore_sys = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo" },
					debounce_ms = 0,
				})
				-- `habamax` installs its own full terminal palette, replacing the
				-- stale one, so the new palette is genuinely the current scheme's.
				vim.cmd.colorscheme("habamax")
				restore_sys()
				restore_palette()

				assert.same({ "theme = habamax" }, vim.fn.readfile(theme_file))
				assert.equals(1, vim.fn.filereadable(themes_dir .. "/habamax"))
				assert.equals(1, #calls)
			end)
		end)

		it("force regenerates with the full live palette even after an unowned colorscheme", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")

				local restore_palette = with_stale_palette()
				local _, restore_sys = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo" },
					debounce_ms = 0,
				})
				-- `default` leaves the palette stale → unowned → mirrored without a palette.
				vim.cmd.colorscheme("default")
				-- ThemeToGhostty forces a regenerate; force trusts the live palette.
				mirror.push("forced", { force = true })
				restore_sys()
				restore_palette()

				assert.same({ "theme = forced" }, vim.fn.readfile(theme_file))
				local forced = table.concat(vim.fn.readfile(themes_dir .. "/forced"), "\n")
				assert.is_truthy(forced:find("palette = 0=", 1, true))
			end)
		end)
	end)

	describe("health", function()
		local function fresh_health()
			package.loaded["ghostty-mirror.health"] = nil
			return require("ghostty-mirror.health")
		end

		it("reports ok for writable paths and a resolvable reload command", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({ themes_dir = dir .. "/themes", theme_file = dir .. "/theme-current", reload_command = { "echo" } })
				local d = fresh_health().diagnostics()
				local errors = vim.tbl_filter(function(e) return e.status == "error" end, d)
				assert.same({}, errors)
			end)
		end)

		it("flags an unresolvable reload command as an error", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({ themes_dir = dir, theme_file = dir .. "/theme-current", reload_command = { "ghostty-mirror-nope-xyzzy" } })
				local d = fresh_health().diagnostics()
				local found = false
				for _, e in ipairs(d) do
					if e.status == "error" and e.msg:find("reload", 1, true) then found = true end
				end
				assert.is_true(found)
			end)
		end)
	end)

	describe("current_scheme", function()
		it("falls back to vim.g.colors_name before any ColorScheme settles", function()
			local saved = vim.g.colors_name
			local mirror = fresh_require()
			mirror.setup({ generate = false })
			vim.g.colors_name = "some_scheme"
			assert.equals("some_scheme", mirror.current_scheme())
			vim.g.colors_name = saved
		end)

		it("prefers the last settled ColorScheme match over vim.g.colors_name", function()
			-- cyberdream sets colors_name='cyberdream' even when you load cyberdream-light;
			-- the ColorScheme event's match carries the real loaded name.
			local saved = vim.g.colors_name
			local _, restore = stub_system()
			local mirror = fresh_require()
			mirror.setup({ generate = false, debounce_ms = 0 })
			vim.g.colors_name = "cyberdream"
			vim.api.nvim_exec_autocmds("ColorScheme", { group = "ghostty-mirror", pattern = "cyberdream-light" })
			restore()
			assert.equals("cyberdream-light", mirror.current_scheme())
			vim.g.colors_name = saved
		end)
	end)
end)
