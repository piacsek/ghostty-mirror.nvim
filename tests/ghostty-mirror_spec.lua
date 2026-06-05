local function with_tmp_dir(fn)
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local ok, err = pcall(fn, dir)
	vim.fn.delete(dir, "rf")
	if not ok then error(err) end
end

---Reload the module fresh so each test gets a clean copy with default config.
---Re-setups the outgoing instance first: that cancels any debounce timer it
---still has armed (setup's idempotence guarantee), which would otherwise fire
---a push under its stale config into some later test's capture window.
local function fresh_require()
	local old = package.loaded["ghostty-mirror"]
	if old then pcall(old.setup, { debounce_ms = 0 }) end
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

---Stub vim.notify to capture messages and levels.
local function stub_notify()
	local notes = {}
	local original = vim.notify
	vim.notify = function(msg, level) ---@diagnostic disable-line: duplicate-set-field
		table.insert(notes, { msg = msg, level = level })
	end
	return notes, function() vim.notify = original end
end

---Run fn with vim.notify captured. Centralizes the deferred-warning dance:
---drains notifications scheduled by earlier tests so they don't leak into this
---capture window, and restores vim.notify even when an assertion throws.
---fn receives the captured notes and a wait(count) that runs the event loop
---until that many notifications arrive (warnings are vim.schedule-deferred).
local function with_notify(fn)
	vim.wait(50)
	local notes, restore = stub_notify()
	local function wait(count)
		vim.wait(200, function() return #notes >= count end)
	end
	local ok, err = pcall(fn, notes, wait)
	restore()
	if not ok then error(err) end
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

	describe("atomic writes and planted destinations", function()
		it("write_generated replaces a symlinked cache path without touching its target", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/themes"
					vim.fn.mkdir(themes_dir, "p")
					local victim = dir .. "/victim"
					vim.fn.writefile({ "precious" }, victim)
					vim.uv.fs_symlink(victim, themes_dir .. "/mytheme")
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					assert.equals("mytheme", mirror.write_generated("mytheme"))
					assert.same({ "precious" }, vim.fn.readfile(victim))
					assert.equals("file", vim.uv.fs_lstat(themes_dir .. "/mytheme").type)
				end)
			end)
		end)

		it("write_tmux_generated replaces a symlinked cache path without touching its target", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/themes"
					vim.fn.mkdir(themes_dir, "p")
					local victim = dir .. "/victim"
					vim.fn.writefile({ "precious" }, victim)
					vim.uv.fs_symlink(victim, themes_dir .. "/mytheme.conf")
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = themes_dir } })
					assert.equals("mytheme", mirror.write_tmux_generated("mytheme"))
					assert.same({ "precious" }, vim.fn.readfile(victim))
					assert.equals("file", vim.uv.fs_lstat(themes_dir .. "/mytheme.conf").type)
				end)
			end)
		end)

		it("write_generated replaces a hard link at the cache path without touching its target", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/themes"
					vim.fn.mkdir(themes_dir, "p")
					local victim = dir .. "/victim"
					vim.fn.writefile({ "precious" }, victim)
					vim.uv.fs_link(victim, themes_dir .. "/mytheme")
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					assert.equals("mytheme", mirror.write_generated("mytheme"))
					assert.same({ "precious" }, vim.fn.readfile(victim))
					assert.equals(1, vim.uv.fs_stat(victim).nlink)
				end)
			end)
		end)

		it("a dangling symlink at the cache path is replaced, not its target created", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/themes"
					vim.fn.mkdir(themes_dir, "p")
					local victim = dir .. "/victim"
					vim.uv.fs_symlink(victim, themes_dir .. "/mytheme")
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					assert.equals("mytheme", mirror.write_generated("mytheme"))
					assert.is_nil(vim.uv.fs_lstat(victim))
					assert.equals("file", vim.uv.fs_lstat(themes_dir .. "/mytheme").type)
				end)
			end)
		end)

		it("push replaces a symlinked theme_file and reloads, leaving the target untouched", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir, theme_file = dir .. "/themes", dir .. "/theme-current"
					vim.fn.mkdir(themes_dir, "p")
					local victim = dir .. "/victim"
					vim.fn.writefile({ "precious" }, victim)
					vim.uv.fs_symlink(victim, theme_file)
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, theme_file = theme_file, reload_command = { "echo" } })
					mirror.push("mytheme", { force = true })
					restore()
					assert.same({ "precious" }, vim.fn.readfile(victim))
					assert.equals("file", vim.uv.fs_lstat(theme_file).type)
					assert.same({ "theme = mytheme" }, vim.fn.readfile(theme_file))
					assert.equals(1, #calls)
				end)
			end)
		end)

		it("a failed write leaves neither a temp file nor a destination behind", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/themes"
					vim.fn.mkdir(themes_dir, "p")
					-- Simulate a partial write (disk full, signal): fs_write reports
					-- fewer bytes than asked. The temp must be cleaned up and the
					-- destination never appear — readers keep whatever was there.
					local real_write = vim.uv.fs_write
					vim.uv.fs_write = function(fd, data, offset) ---@diagnostic disable-line: duplicate-set-field
						real_write(fd, data, offset)
						return #data - 1
					end
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					local ok, result = pcall(mirror.write_generated, "mytheme")
					vim.uv.fs_write = real_write
					assert.is_true(ok, tostring(result))
					assert.is_nil(result)
					local entries = {}
					for name in vim.fs.dir(themes_dir) do
						table.insert(entries, name)
					end
					assert.same({}, entries)
				end)
			end)
		end)

		it("fsyncs the destination directory after the rename so the write survives a crash", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/themes"
					vim.fn.mkdir(themes_dir, "p")
					-- Map fds back to paths so the fsync capture can tell the
					-- directory's fsync from the temp file's.
					local opened, fsynced = {}, {}
					local real_open, real_fsync = vim.uv.fs_open, vim.uv.fs_fsync
					vim.uv.fs_open = function(path, flags, mode) ---@diagnostic disable-line: duplicate-set-field
						local fd = real_open(path, flags, mode)
						if fd then opened[fd] = path end
						return fd
					end
					vim.uv.fs_fsync = function(fd) ---@diagnostic disable-line: duplicate-set-field
						table.insert(fsynced, opened[fd])
						return real_fsync(fd)
					end
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					local ok, result = pcall(mirror.write_generated, "mytheme")
					vim.uv.fs_open, vim.uv.fs_fsync = real_open, real_fsync
					assert.is_true(ok, tostring(result))
					assert.equals("mytheme", result)
					assert.is_true(vim.tbl_contains(fsynced, themes_dir))
				end)
			end)
		end)

		it("push_tmux replaces a symlinked tmux theme_file and reloads, leaving the target untouched", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir, theme_file = dir .. "/themes", dir .. "/theme-current.conf"
					vim.fn.mkdir(themes_dir, "p")
					local victim = dir .. "/victim"
					vim.fn.writefile({ "precious" }, victim)
					vim.uv.fs_symlink(victim, theme_file)
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = themes_dir, theme_file = theme_file } })
					mirror.push_tmux("mytheme", { force = true })
					restore()
					assert.same({ "precious" }, vim.fn.readfile(victim))
					assert.equals("file", vim.uv.fs_lstat(theme_file).type)
					assert.equals(1, #calls)
				end)
			end)
		end)
	end)

	describe("force push over hand-made theme files", function()
		it("push refuses to overwrite a hand-made theme file without clobber", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir, theme_file = dir .. "/themes", dir .. "/theme-current"
					vim.fn.mkdir(themes_dir, "p")
					vim.fn.writefile({ "background = #123456" }, themes_dir .. "/mytheme")
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, theme_file = theme_file, reload_command = { "echo" } })
					local name = mirror.push("mytheme", { force = true })
					restore()
					assert.is_nil(name)
					assert.same({ "background = #123456" }, vim.fn.readfile(themes_dir .. "/mytheme"))
					assert.equals(0, #calls)
				end)
			end)
		end)

		it("push warns when refusing a hand-made theme file", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/themes"
					vim.fn.mkdir(themes_dir, "p")
					vim.fn.writefile({ "background = #123456" }, themes_dir .. "/mytheme")
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, theme_file = dir .. "/theme-current" })
					with_notify(function(notes)
						mirror.push("mytheme", { force = true })
						assert.equals(1, #notes)
						assert.truthy(notes[1].msg:find("hand%-made"))
						assert.equals(vim.log.levels.WARN, notes[1].level)
					end)
				end)
			end)
		end)

		it("push with clobber overwrites a hand-made theme file", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir, theme_file = dir .. "/themes", dir .. "/theme-current"
					vim.fn.mkdir(themes_dir, "p")
					vim.fn.writefile({ "background = #123456" }, themes_dir .. "/mytheme")
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, theme_file = theme_file, reload_command = { "echo" } })
					local name = mirror.push("mytheme", { force = true, clobber = true })
					restore()
					assert.equals("mytheme", name)
					assert.truthy(vim.fn.readfile(themes_dir .. "/mytheme")[1]:find("^# Generated by ghostty%-mirror"))
					assert.equals(1, #calls)
				end)
			end)
		end)

		it("push_tmux refuses to overwrite a hand-made tmux theme file without clobber", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir, theme_file = dir .. "/themes", dir .. "/theme-current.conf"
					vim.fn.mkdir(themes_dir, "p")
					vim.fn.writefile({ "set -g status-style bg=#123456" }, themes_dir .. "/mytheme.conf")
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = themes_dir, theme_file = theme_file } })
					local name = mirror.push_tmux("mytheme", { force = true })
					restore()
					assert.is_nil(name)
					assert.same({ "set -g status-style bg=#123456" }, vim.fn.readfile(themes_dir .. "/mytheme.conf"))
					assert.equals(0, #calls)
				end)
			end)
		end)

		it("push_tmux's refusal warning names the tmux bang, not the Ghostty one", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/themes"
					vim.fn.mkdir(themes_dir, "p")
					vim.fn.writefile({ "set -g status-style bg=#123456" }, themes_dir .. "/mytheme.conf")
					local mirror = fresh_require()
					mirror.setup({
						tmux = { enabled = true, themes_dir = themes_dir, theme_file = dir .. "/theme-current.conf" },
					})
					with_notify(function(notes)
						mirror.push_tmux("mytheme", { force = true })
						assert.equals(1, #notes)
						assert.truthy(notes[1].msg:find(":ThemeToTmux!", 1, true))
						assert.is_nil(notes[1].msg:find("ThemeToGhostty", 1, true))
					end)
				end)
			end)
		end)

		it("push_tmux with clobber overwrites a hand-made tmux theme file", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir, theme_file = dir .. "/themes", dir .. "/theme-current.conf"
					vim.fn.mkdir(themes_dir, "p")
					vim.fn.writefile({ "set -g status-style bg=#123456" }, themes_dir .. "/mytheme.conf")
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = themes_dir, theme_file = theme_file } })
					local name = mirror.push_tmux("mytheme", { force = true, clobber = true })
					restore()
					assert.equals("mytheme", name)
					assert.truthy(
						vim.fn.readfile(themes_dir .. "/mytheme.conf")[1]:find("^# Generated by ghostty%-mirror")
					)
					assert.equals(1, #calls)
				end)
			end)
		end)

		it("push's clobber stays scoped to Ghostty: the chained tmux push won't clobber", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local g_themes, t_themes = dir .. "/g", dir .. "/t"
					vim.fn.mkdir(g_themes, "p")
					vim.fn.mkdir(t_themes, "p")
					vim.fn.writefile({ "background = #123456" }, g_themes .. "/mytheme")
					vim.fn.writefile({ "set -g status-style bg=#123456" }, t_themes .. "/mytheme.conf")
					local _, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({
						themes_dir = g_themes,
						theme_file = dir .. "/g-current",
						reload_command = { "echo" },
						tmux = { enabled = true, themes_dir = t_themes, theme_file = dir .. "/t-current.conf" },
					})
					local name = mirror.push("mytheme", { force = true, clobber = true })
					restore()
					assert.equals("mytheme", name)
					assert.truthy(vim.fn.readfile(g_themes .. "/mytheme")[1]:find("^# Generated by ghostty%-mirror"))
					assert.same({ "set -g status-style bg=#123456" }, vim.fn.readfile(t_themes .. "/mytheme.conf"))
				end)
			end)
		end)

		it(":ThemeToGhostty refuses a hand-made theme file; the bang clobbers it", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir, theme_file = dir .. "/themes", dir .. "/theme-current"
					vim.fn.mkdir(themes_dir, "p")
					vim.fn.writefile({ "background = #123456" }, themes_dir .. "/mytheme")
					local saved_colors_name = vim.g.colors_name
					vim.g.colors_name = "mytheme"
					local _, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, theme_file = theme_file, reload_command = { "echo" } })
					local ok, err = pcall(function()
						vim.cmd("ThemeToGhostty")
						assert.same({ "background = #123456" }, vim.fn.readfile(themes_dir .. "/mytheme"))
						vim.cmd("ThemeToGhostty!")
						assert.truthy(
							vim.fn.readfile(themes_dir .. "/mytheme")[1]:find("^# Generated by ghostty%-mirror")
						)
					end)
					restore()
					vim.g.colors_name = saved_colors_name
					if not ok then error(err) end
				end)
			end)
		end)

		it(":ThemeToTmux refuses a hand-made theme file; the bang clobbers it", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir, theme_file = dir .. "/themes", dir .. "/theme-current.conf"
					vim.fn.mkdir(themes_dir, "p")
					vim.fn.writefile({ "set -g status-style bg=#123456" }, themes_dir .. "/mytheme.conf")
					local saved_colors_name = vim.g.colors_name
					vim.g.colors_name = "mytheme"
					local _, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = themes_dir, theme_file = theme_file } })
					local ok, err = pcall(function()
						vim.cmd("ThemeToTmux")
						assert.same(
							{ "set -g status-style bg=#123456" },
							vim.fn.readfile(themes_dir .. "/mytheme.conf")
						)
						vim.cmd("ThemeToTmux!")
						assert.truthy(
							vim.fn.readfile(themes_dir .. "/mytheme.conf")[1]:find("^# Generated by ghostty%-mirror")
						)
					end)
					restore()
					vim.g.colors_name = saved_colors_name
					if not ok then error(err) end
				end)
			end)
		end)
	end)

	describe("non-regular read sources", function()
		it("read_current refuses a FIFO planted at theme_file without blocking", function()
			with_tmp_dir(function(dir)
				local theme_file = dir .. "/theme-current"
				vim.system({ "mkfifo", theme_file }):wait()
				local mirror = fresh_require()
				mirror.setup({ theme_file = theme_file })
				assert.is_nil(mirror.read_current())
			end)
		end)

		it("read_current does not parse past the read cap of an oversized file", function()
			with_tmp_dir(function(dir)
				local theme_file = dir .. "/theme-current"
				local lines = {}
				for _ = 1, 2048 do
					table.insert(lines, string.rep("#", 32))
				end
				table.insert(lines, "theme = elflord")
				vim.fn.writefile(lines, theme_file)
				local mirror = fresh_require()
				mirror.setup({ theme_file = theme_file })
				assert.is_nil(mirror.read_current())
			end)
		end)
	end)

	describe("hostile colorscheme names", function()
		it("resolve refuses a path-traversal name and writes nothing", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/themes"
					vim.fn.mkdir(themes_dir, "p")
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					assert.is_nil(mirror.resolve("../escape"))
					assert.equals(0, vim.fn.filereadable(dir .. "/escape"))
				end)
			end)
		end)
		it("push refuses a newline-injecting name even when forced", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir, theme_file = dir .. "/themes", dir .. "/theme-current"
					vim.fn.mkdir(themes_dir, "p")
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, theme_file = theme_file, reload_command = { "echo" } })
					assert.is_nil(mirror.push("foo\nbackground = #ff0000", { force = true }))
					restore()
					assert.equals(0, vim.fn.filereadable(theme_file))
					assert.equals(0, #calls)
				end)
			end)
		end)
		it("push_tmux refuses a quote-injecting name even when forced", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local t = dir .. "/t"
					vim.fn.mkdir(t, "p")
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({
						tmux = { enabled = true, themes_dir = t, theme_file = dir .. "/tc.conf" },
					})
					assert.is_nil(mirror.push_tmux('foo"; run-shell evil; "', { force = true }))
					restore()
					assert.equals(0, vim.fn.filereadable(dir .. "/tc.conf"))
					assert.equals(0, #calls)
				end)
			end)
		end)

		it("resolve_tmux refuses a path-traversal name", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = dir } })
					assert.is_nil(mirror.resolve_tmux("../escape"))
				end)
			end)
		end)

		it("pull refuses a path-traversal name planted in theme_file", function()
			with_tmp_dir(function(dir)
				local before = vim.g.colors_name
				vim.fn.writefile({ "theme = ../../../tmp/payload" }, dir .. "/theme-current")
				local notices, restore = stub_notify()
				local mirror = fresh_require()
				mirror.setup({ themes_dir = dir, theme_file = dir .. "/theme-current", generate = false })
				mirror.pull()
				restore()
				assert.equals(before, vim.g.colors_name)
				assert.equals(1, #notices)
				assert.equals(vim.log.levels.WARN, notices[1].level)
				assert.is_truthy(notices[1].msg:find("could not read theme", 1, true))
			end)
		end)

		it("resolve and resolve_tmux refuse an empty name", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({ themes_dir = dir, tmux = { enabled = true, themes_dir = dir } })
				assert.is_nil(mirror.resolve(""))
				assert.is_nil(mirror.resolve_tmux(""))
			end)
		end)

		it("write_generated and write_tmux_generated refuse a path-traversal name themselves", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/themes"
					vim.fn.mkdir(themes_dir, "p")
					local mirror = fresh_require()
					mirror.setup({
						themes_dir = themes_dir,
						tmux = { enabled = true, themes_dir = themes_dir },
					})
					assert.is_nil(mirror.write_generated("../escape"))
					assert.is_nil(mirror.write_tmux_generated("../escape"))
					assert.equals(0, vim.fn.filereadable(dir .. "/escape"))
					assert.equals(0, vim.fn.filereadable(dir .. "/escape.conf"))
				end)
			end)
		end)

		it("generate refuses a newline-injecting name itself", function()
			with_palette(function()
				-- The name lands verbatim in the returned header line; a newline in
				-- it carries an injected directive. All internal callers guard via
				-- write_generated, but generate is public API and must self-guard.
				local mirror = fresh_require()
				mirror.setup({ generate = true })
				assert.is_nil(mirror.generate("foo\nbackground = #ff0000"))
			end)
		end)

		it("generate_tmux refuses a newline-injecting name itself", function()
			with_palette(function()
				-- Same self-guard as generate: the header line is part of a file
				-- tmux executes, so a newline carries an injected command.
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true } })
				assert.is_nil(mirror.generate_tmux("foo\nrun-shell evil"))
			end)
		end)

		it("push_tmux refuses a tmux.themes_dir mutated to unsafe values after setup", function()
			-- setup() validates tmux.themes_dir, but M.config is plain data any
			-- code can mutate afterwards; the dir lands inside the quoted
			-- source-file line tmux executes, so the sink must re-refuse it.
			with_palette(function()
				for _, bad in ipairs({ '"', "\\", "\n" }) do
					with_tmp_dir(function(dir)
						local t = dir .. "/t"
						vim.fn.mkdir(t, "p")
						local calls, restore = stub_system()
						local mirror = fresh_require()
						mirror.setup({ tmux = { enabled = true, themes_dir = t, theme_file = dir .. "/tc.conf" } })
						mirror.config.tmux.themes_dir = t .. bad .. "x"
						mirror.push_tmux("mytheme", { force = true })
						restore()
						assert.equals(0, vim.fn.filereadable(dir .. "/tc.conf"), ("pointer written for %q"):format(bad))
						assert.equals(0, #calls, ("reload fired for %q"):format(bad))
					end)
				end
			end)
		end)

		it("a light_variant_suffix mutated to an unsafe value after setup is ignored at use", function()
			-- setup() errors on an unsafe suffix, but M.config is plain data any
			-- code can mutate afterwards; the suffix extends already-validated
			-- names into the same paths and pointer lines, so at use an unsafe
			-- value must read as disabled rather than ride a validated name out.
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ themes_dir = dir })
					mirror.config.light_variant_suffix = '"\n-evil'
					vim.o.background = "light"
					local name = mirror.resolve("mytheme")
					vim.o.background = "dark"
					assert.equals("mytheme", name)
					assert.equals(1, vim.fn.filereadable(dir .. "/mytheme"))
				end)
			end)
		end)

		it("resolve and resolve_tmux refuse the bare dot names", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({ themes_dir = dir, tmux = { enabled = true, themes_dir = dir } })
				assert.is_nil(mirror.resolve("."))
				assert.is_nil(mirror.resolve(".."))
				assert.is_nil(mirror.resolve_tmux("."))
				assert.is_nil(mirror.resolve_tmux(".."))
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

		it("emits selection-foreground and cursor-text from Visual.fg / Cursor.fg", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Visual", { bg = 0x45475a, fg = 0xcdd6f4 })
				vim.api.nvim_set_hl(0, "Cursor", { bg = 0xf5e0dc, fg = 0x1e1e2e })
				local mirror = fresh_require()
				mirror.setup({ generate = true })
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_truthy(joined:find("selection%-background = #45475a"))
				assert.is_truthy(joined:find("selection%-foreground = #cdd6f4"))
				assert.is_truthy(joined:find("cursor%-color = #f5e0dc"))
				assert.is_truthy(joined:find("cursor%-text = #1e1e2e"))
			end)
		end)

		it("omits a color whose highlight value does not fit 24 bits", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Cursor", { bg = 0x1f5e0dc })
				local mirror = fresh_require()
				mirror.setup({ generate = true })
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_nil(joined:find("cursor%-color"))
			end)
		end)

		it("omits selection-foreground and cursor-text when those fg colors are absent", function()
			with_palette(function()
				-- with_palette sets Visual/Cursor with bg only (no fg)
				local mirror = fresh_require()
				mirror.setup({ generate = true })
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_nil(joined:find("selection%-foreground"))
				assert.is_nil(joined:find("cursor%-text"))
			end)
		end)

		it("falls back to Cursor.fg for cursor-color when Cursor has no bg, still omitting cursor-text", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Cursor", { fg = 0xf5e0dc })
				local mirror = fresh_require()
				mirror.setup({ generate = true })
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_truthy(joined:find("cursor%-color = #f5e0dc"))
				-- fg-only means cursor-color above *is* the fg; emitting it again as
				-- the glyph color would render an invisible block cursor.
				assert.is_nil(joined:find("cursor%-text"))
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

		it("omits the palette when a slot smuggles a directive behind a newline", function()
			with_palette(function()
				vim.g.terminal_color_5 = "#000000\ncommand = evil"
				local mirror = fresh_require()
				mirror.setup({ generate = true })
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_nil(joined:find("command = evil", 1, true))
				assert.is_nil(joined:find("palette = ", 1, true))
			end)
		end)

		it("normalizes shorthand and uppercase palette slots instead of dropping the palette", function()
			with_palette(function()
				vim.g.terminal_color_5 = "#F00"
				local mirror = fresh_require()
				mirror.setup({ generate = true })
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_truthy(joined:find("palette = 5=#ff0000", 1, true))
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

	describe("generate: overrides", function()
		it("a foreground override replaces the Normal-derived value; background stays the scheme's own", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({ overrides = { mytheme = { foreground = "#aabbcc" } } })
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_truthy(joined:find("foreground = #aabbcc", 1, true))
				assert.is_truthy(joined:find("background = #1e1e2e", 1, true))
				assert.is_nil(joined:find("#cdd6f4", 1, true))
			end)
		end)

		it("maps underscore params onto the dashed cursor and selection directives", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Visual", { bg = 0x45475a, fg = 0xcdd6f4 })
				vim.api.nvim_set_hl(0, "Cursor", { bg = 0xf5e0dc, fg = 0x1e1e2e })
				local mirror = fresh_require()
				mirror.setup({
					overrides = {
						mytheme = {
							cursor_color = "#ffaabb",
							cursor_text = "#001122",
							selection_background = "#334455",
							selection_foreground = "#667788",
						},
					},
				})
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_truthy(joined:find("cursor-color = #ffaabb", 1, true))
				assert.is_truthy(joined:find("cursor-text = #001122", 1, true))
				assert.is_truthy(joined:find("selection-background = #334455", 1, true))
				assert.is_truthy(joined:find("selection-foreground = #667788", 1, true))
			end)
		end)

		it("force-emits a conditional directive the highlight alone would omit", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Cursor", {})
				vim.api.nvim_set_hl(0, "Visual", {})
				local mirror = fresh_require()
				mirror.setup({
					overrides = {
						mytheme = {
							cursor_color = "#ffaabb",
							cursor_text = "#001122",
							selection_background = "#334455",
							selection_foreground = "#667788",
						},
					},
				})
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_truthy(joined:find("cursor-color = #ffaabb", 1, true))
				assert.is_truthy(joined:find("cursor-text = #001122", 1, true))
				assert.is_truthy(joined:find("selection-background = #334455", 1, true))
				assert.is_truthy(joined:find("selection-foreground = #667788", 1, true))
			end)
		end)

		it("normalizes a #rgb shorthand color to lowercase #rrggbb", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({ overrides = { mytheme = { foreground = "#FfA" } } })
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_truthy(joined:find("foreground = #ffffaa", 1, true))
			end)
		end)

		it("falls back to the highlight-derived value when the override color is invalid", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({ overrides = { mytheme = { foreground = "nope" } } })
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_truthy(joined:find("foreground = #cdd6f4", 1, true))
			end)
		end)

		it("keys overrides by the resolved name, so the light variant gets its own entry", function()
			vim.o.background = "light"
			vim.api.nvim_set_hl(0, "Normal", { fg = 0x000000, bg = 0xe4e4e4 })
			local mirror = fresh_require()
			mirror.setup({
				overrides = {
					mytheme = { foreground = "#111111" },
					["mytheme-light"] = { foreground = "#fafafa" },
				},
			})
			local joined = table.concat(mirror.generate("mytheme"), "\n")
			assert.is_truthy(joined:find("foreground = #fafafa", 1, true))
			vim.o.background = "dark"
		end)

		it("generates the unmodified theme for an empty override table", function()
			with_palette(function()
				with_notify(function(notes)
					local mirror = fresh_require()
					mirror.setup({})
					local plain = mirror.generate("elflord")
					mirror.setup({ overrides = { elflord = {} } })
					local overridden = mirror.generate("elflord")
					vim.wait(50)
					assert.same(plain, overridden)
					assert.same({}, notes)
				end)
			end)
		end)

		it("substitutes palette slot overrides into an owned palette", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({ overrides = { mytheme = { palette = { [3] = "#cc8800" } } } })
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_truthy(joined:find("palette = 3=#cc8800", 1, true))
				-- the other 15 slots stay the live palette's own
				assert.is_truthy(joined:find("palette = 0=#000000", 1, true))
				assert.is_truthy(joined:find("palette = 15=#0f0000", 1, true))
			end)
		end)

		it("emits overridden slots as a partial palette when the scheme owns none", function()
			with_palette(function()
				-- an incomplete live palette is never mirrored (see palette ownership);
				-- explicit slot overrides outrank that caution for their own slots
				vim.g.terminal_color_7 = nil
				local mirror = fresh_require()
				mirror.setup({ overrides = { mytheme = { palette = { [3] = "#cc8800", [9] = "#11aa22" } } } })
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_truthy(joined:find("palette = 3=#cc8800", 1, true))
				assert.is_truthy(joined:find("palette = 9=#11aa22", 1, true))
				assert.is_nil(joined:find("palette = 0=", 1, true))
			end)
		end)

		it("drops bad palette slots and colors while the valid rest applies", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({
					overrides = { mytheme = { palette = { [3] = "#cc8800", [16] = "#111111", [4] = "zzz" } } },
				})
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_truthy(joined:find("palette = 3=#cc8800", 1, true))
				assert.is_truthy(joined:find("palette = 4=#040000", 1, true))
				assert.is_nil(joined:find("16=", 1, true))
			end)
		end)

		it("does not emit a palette for an empty palette table when the scheme owns none", function()
			with_palette(function()
				vim.g.terminal_color_7 = nil
				local mirror = fresh_require()
				mirror.setup({ overrides = { mytheme = { palette = {} } } })
				local joined = table.concat(mirror.generate("mytheme"), "\n")
				assert.is_nil(joined:find("palette = ", 1, true))
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

		it("never emits a malformed color even when the configured blend is out of range", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true, bar_blend = 7 } })
				for _, line in ipairs(mirror.generate_tmux("mytheme")) do
					for color in line:gmatch("#%x+") do
						assert.equals(7, #color, "malformed color " .. color .. " in: " .. line)
					end
				end
			end)
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

	describe("generate_tmux: overrides", function()
		it("an accent override replaces the accent_hl-derived accent", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true, overrides = { mytheme = { accent = "#ff00aa" } } } })
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				assert.is_truthy(joined:find('window%-status%-current%-style "bg=#ff00aa'))
				assert.is_truthy(joined:find('pane%-active%-border%-style "fg=#ff00aa'))
			end)
		end)

		it("a divider override replaces the divider_hl-derived pane border color", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true, overrides = { mytheme = { divider = "#123456" } } } })
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				assert.is_truthy(joined:find('set %-g pane%-border%-style "fg=#123456"'))
			end)
		end)

		it("a bar override sets the bar segments directly, bypassing the blend", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({
					tmux = { enabled = true, overrides = { mytheme = { bar = "#3a0054", bar_blend = 0.5 } } },
				})
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				assert.is_truthy(joined:find('set %-g status%-style "bg=#3a0054'))
				assert.is_truthy(joined:find('set %-g status%-left%-style "bg=#3a0054'))
				assert.is_truthy(joined:find('set %-g window%-status%-style "bg=#3a0054'))
				assert.is_truthy(joined:find('set %-g message%-style "bg=#3a0054'))
			end)
		end)

		it("normalizes a #rgb shorthand color to lowercase #rrggbb", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true, overrides = { mytheme = { accent = "#FfA" } } } })
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				assert.is_truthy(joined:find('window%-status%-current%-style "bg=#ffffaa'))
			end)
		end)

		it("falls back to the blended bar when the bar override color is invalid", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Type", { fg = 0xff00ff })
				local mirror = fresh_require()
				mirror.setup({
					tmux = { enabled = true, bar_blend = 0.25, overrides = { mytheme = { bar = "nope" } } },
				})
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				assert.equals("#561762", joined:match('status%-style "bg=(#%x%x%x%x%x%x)'))
			end)
		end)

		it("falls back to the highlight-derived divider when the override color is invalid", function()
			with_palette(function()
				local saved = vim.api.nvim_get_hl(0, { name = "WinSeparator" })
				vim.api.nvim_set_hl(0, "WinSeparator", { fg = 0x44475a })
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true, overrides = { mytheme = { divider = "nope" } } } })
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				vim.api.nvim_set_hl(0, "WinSeparator", saved)
				assert.is_truthy(joined:find('set %-g pane%-border%-style "fg=#44475a"'))
			end)
		end)

		it("generates the unmodified theme for an empty override table", function()
			with_palette(function()
				with_notify(function(notes)
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true } })
					local plain = mirror.generate_tmux("elflord")
					mirror.setup({ tmux = { enabled = true, overrides = { elflord = {} } } })
					local overridden = mirror.generate_tmux("elflord")
					vim.wait(50)
					assert.same(plain, overridden)
					assert.same({}, notes)
				end)
			end)
		end)

		it("keys overrides by the resolved name, so the light variant gets its own entry", function()
			vim.o.background = "light"
			vim.api.nvim_set_hl(0, "Normal", { fg = 0x000000, bg = 0xe4e4e4 })
			vim.api.nvim_set_hl(0, "Type", { fg = 0x2e8b57 })
			local mirror = fresh_require()
			mirror.setup({
				tmux = {
					enabled = true,
					overrides = {
						mytheme = { accent = "#111111" },
						["mytheme-light"] = { accent = "#222222" },
					},
				},
			})
			local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
			assert.is_truthy(joined:find('window%-status%-current%-style "bg=#222222'))
			vim.o.background = "dark"
		end)

		it("falls back to the configured blend when the bar_blend override is out of range", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Type", { fg = 0xff00ff })
				local mirror = fresh_require()
				mirror.setup({
					tmux = { enabled = true, bar_blend = 0.25, overrides = { mytheme = { bar_blend = 7 } } },
				})
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				assert.equals("#561762", joined:match('status%-style "bg=(#%x%x%x%x%x%x)'))
			end)
		end)

		it("falls back to the configured blend when the bar_blend override is not a number", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Type", { fg = 0xff00ff })
				local mirror = fresh_require()
				mirror.setup({
					tmux = { enabled = true, bar_blend = 0.25, overrides = { mytheme = { bar_blend = "half" } } },
				})
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				assert.equals("#561762", joined:match('status%-style "bg=(#%x%x%x%x%x%x)'))
			end)
		end)

		it("a bar_blend override replaces the configured blend amount", function()
			with_palette(function()
				vim.api.nvim_set_hl(0, "Type", { fg = 0xff00ff })
				local mirror = fresh_require()
				mirror.setup({
					tmux = { enabled = true, bar_blend = 0.25, overrides = { mytheme = { bar_blend = 0.5 } } },
				})
				local joined = table.concat(mirror.generate_tmux("mytheme"), "\n")
				assert.equals("#8f0f97", joined:match('status%-style "bg=(#%x%x%x%x%x%x)'))
			end)
		end)
	end)

	describe("write_generated: override stamp", function()
		it("stamps the normalized effective overrides, flattening palette slots", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({
						themes_dir = dir,
						overrides = {
							elflord = { foreground = "#101010", cursor_color = "#FfA", palette = { [3] = "#cc8800" } },
						},
					})
					mirror.write_generated("elflord")
					local lines = vim.fn.readfile(dir .. "/elflord")
					assert.equals("# overrides: cursor_color=#ffffaa,foreground=#101010,palette3=#cc8800", lines[2])
				end)
			end)
		end)

		it("writes no stamp line when no overrides apply, keeping the legacy format", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ themes_dir = dir })
					mirror.write_generated("elflord")
					local lines = vim.fn.readfile(dir .. "/elflord")
					assert.is_truthy(vim.startswith(lines[2], "background = "))
				end)
			end)
		end)

		it("a stamped file still counts as generated, so clear_cache deletes it", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ themes_dir = dir, overrides = { elflord = { foreground = "#101010" } } })
					mirror.write_generated("elflord")
					assert.is_true(vim.tbl_contains(mirror.clear_cache(), "elflord"))
					assert.equals(0, vim.fn.filereadable(dir .. "/elflord"))
				end)
			end)
		end)
	end)

	describe("write_tmux_generated: override stamp", function()
		it("stamps the normalized effective overrides into the generated header", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({
						tmux = {
							enabled = true,
							themes_dir = dir,
							overrides = { elflord = { bar_blend = 0.3, accent = "#FfA", bar = "#3a0054" } },
						},
					})
					mirror.write_tmux_generated("elflord")
					local lines = vim.fn.readfile(dir .. "/elflord.conf")
					assert.equals("# overrides: accent=#ffffaa,bar=#3a0054,bar_blend=0.3", lines[2])
				end)
			end)
		end)

		it("writes no stamp line when no overrides apply, keeping the legacy format", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = dir } })
					mirror.write_tmux_generated("elflord")
					local lines = vim.fn.readfile(dir .. "/elflord.conf")
					assert.is_truthy(vim.startswith(lines[2], "set -g status-style"))
				end)
			end)
		end)
	end)

	describe("resolve: stale override caches", function()
		it("regenerates a generated cache when an override is added for it", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ themes_dir = dir })
					mirror.write_generated("elflord")
					mirror.setup({ themes_dir = dir, overrides = { elflord = { foreground = "#101010" } } })
					assert.equals("elflord", mirror.resolve("elflord"))
					local joined = table.concat(vim.fn.readfile(dir .. "/elflord"), "\n")
					assert.is_truthy(joined:find("foreground = #101010", 1, true))
				end)
			end)
		end)

		it("regenerates back to vanilla when the override is removed", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ themes_dir = dir, overrides = { elflord = { foreground = "#101010" } } })
					mirror.write_generated("elflord")
					mirror.setup({ themes_dir = dir })
					assert.equals("elflord", mirror.resolve("elflord"))
					local joined = table.concat(vim.fn.readfile(dir .. "/elflord"), "\n")
					assert.is_nil(joined:find("#101010", 1, true))
					assert.is_nil(joined:find("# overrides:", 1, true))
				end)
			end)
		end)

		it("leaves a hand-made file untouched even when an override is configured", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					vim.fn.writefile({ "background = #abcdef" }, dir .. "/elflord")
					local mirror = fresh_require()
					mirror.setup({ themes_dir = dir, overrides = { elflord = { foreground = "#101010" } } })
					assert.equals("elflord", mirror.resolve("elflord"))
					assert.same({ "background = #abcdef" }, vim.fn.readfile(dir .. "/elflord"))
				end)
			end)
		end)

		it("keeps serving a stale cache when generation is disabled", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ themes_dir = dir, overrides = { elflord = { foreground = "#101010" } } })
					mirror.write_generated("elflord")
					mirror.setup({ themes_dir = dir, generate = false })
					assert.equals("elflord", mirror.resolve("elflord"))
					local joined = table.concat(vim.fn.readfile(dir .. "/elflord"), "\n")
					assert.is_truthy(joined:find("#101010", 1, true))
				end)
			end)
		end)

		it("does not rewrite an unstamped generated cache when no overrides apply", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ themes_dir = dir })
					mirror.write_generated("elflord")
					local sentinel = vim.fn.readfile(dir .. "/elflord")
					table.insert(sentinel, "# user tweak kept on resolve")
					vim.fn.writefile(sentinel, dir .. "/elflord")
					assert.equals("elflord", mirror.resolve("elflord"))
					local joined = table.concat(vim.fn.readfile(dir .. "/elflord"), "\n")
					assert.is_truthy(joined:find("# user tweak kept on resolve", 1, true))
				end)
			end)
		end)

		it("returns regenerated = true only when the call (re)generated the file", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ themes_dir = dir })
					local name, regenerated = mirror.resolve("elflord")
					assert.equals("elflord", name)
					assert.is_true(regenerated)
					name, regenerated = mirror.resolve("elflord")
					assert.equals("elflord", name)
					assert.is_falsy(regenerated)
				end)
			end)
		end)
	end)

	describe("resolve_tmux: stale override caches", function()
		it("regenerates a generated cache when an override is added for it", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = dir } })
					mirror.write_tmux_generated("elflord")
					mirror.setup({
						tmux = { enabled = true, themes_dir = dir, overrides = { elflord = { accent = "#ff00aa" } } },
					})
					assert.equals("elflord", mirror.resolve_tmux("elflord"))
					local joined = table.concat(vim.fn.readfile(dir .. "/elflord.conf"), "\n")
					assert.is_truthy(joined:find('window%-status%-current%-style "bg=#ff00aa'))
				end)
			end)
		end)

		it("regenerates back to vanilla when the override is removed", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({
						tmux = { enabled = true, themes_dir = dir, overrides = { elflord = { accent = "#ff00aa" } } },
					})
					mirror.write_tmux_generated("elflord")
					mirror.setup({ tmux = { enabled = true, themes_dir = dir } })
					assert.equals("elflord", mirror.resolve_tmux("elflord"))
					local joined = table.concat(vim.fn.readfile(dir .. "/elflord.conf"), "\n")
					assert.is_nil(joined:find("#ff00aa", 1, true))
					assert.is_nil(joined:find("# overrides:", 1, true))
				end)
			end)
		end)

		it("leaves a hand-made .conf untouched even when an override is configured", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					vim.fn.writefile({ 'set -g status-style "bg=#abcdef"' }, dir .. "/elflord.conf")
					local mirror = fresh_require()
					mirror.setup({
						tmux = { enabled = true, themes_dir = dir, overrides = { elflord = { accent = "#ff00aa" } } },
					})
					assert.equals("elflord", mirror.resolve_tmux("elflord"))
					assert.same({ 'set -g status-style "bg=#abcdef"' }, vim.fn.readfile(dir .. "/elflord.conf"))
				end)
			end)
		end)

		it("keeps serving a stale cache when generation is disabled", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({
						tmux = { enabled = true, themes_dir = dir, overrides = { elflord = { accent = "#ff00aa" } } },
					})
					mirror.write_tmux_generated("elflord")
					mirror.setup({ tmux = { enabled = true, themes_dir = dir, generate = false } })
					assert.equals("elflord", mirror.resolve_tmux("elflord"))
					local joined = table.concat(vim.fn.readfile(dir .. "/elflord.conf"), "\n")
					assert.is_truthy(joined:find("#ff00aa", 1, true))
				end)
			end)
		end)

		it("does not rewrite an unstamped generated cache when no overrides apply", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = dir } })
					mirror.write_tmux_generated("elflord")
					local sentinel = vim.fn.readfile(dir .. "/elflord.conf")
					table.insert(sentinel, "# user tweak kept on resolve")
					vim.fn.writefile(sentinel, dir .. "/elflord.conf")
					assert.equals("elflord", mirror.resolve_tmux("elflord"))
					local joined = table.concat(vim.fn.readfile(dir .. "/elflord.conf"), "\n")
					assert.is_truthy(joined:find("# user tweak kept on resolve", 1, true))
				end)
			end)
		end)
	end)

	describe("push: regenerated cache under an unchanged pointer", function()
		it("still runs the reload so the override change reaches Ghostty", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local g = dir .. "/g"
					vim.fn.mkdir(g, "p")
					local base = { themes_dir = g, theme_file = dir .. "/g-current", reload_command = { "echo" } }
					local mirror = fresh_require()
					mirror.setup(base)
					local _, restore_seed = stub_system()
					mirror.push("elflord")
					restore_seed()
					mirror.setup(
						vim.tbl_extend("force", base, { overrides = { elflord = { foreground = "#101010" } } })
					)
					local calls, restore = stub_system()
					mirror.push("elflord")
					restore()
					local joined = table.concat(vim.fn.readfile(g .. "/elflord"), "\n")
					assert.is_truthy(joined:find("#101010", 1, true))
					assert.equals(1, #calls)
				end)
			end)
		end)
	end)

	describe("push_tmux: regenerated cache under an unchanged pointer", function()
		it("still runs the reload so the override change reaches tmux", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local t = dir .. "/t"
					vim.fn.mkdir(t, "p")
					local base =
						{ enabled = true, themes_dir = t, theme_file = dir .. "/tc.conf", reload_command = { "echo" } }
					local mirror = fresh_require()
					mirror.setup({ tmux = base })
					local _, restore_seed = stub_system()
					mirror.push_tmux("elflord")
					restore_seed()
					mirror.setup({
						tmux = vim.tbl_extend("force", base, { overrides = { elflord = { accent = "#ff00aa" } } }),
					})
					local calls, restore = stub_system()
					mirror.push_tmux("elflord")
					restore()
					local joined = table.concat(vim.fn.readfile(t .. "/elflord.conf"), "\n")
					assert.is_truthy(joined:find("#ff00aa", 1, true))
					assert.equals(1, #calls)
				end)
			end)
		end)
	end)

	describe("integration: ghostty override edit across a restart", function()
		it("startup sync regenerates a stale-stamped cache and reloads Ghostty", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local g = dir .. "/g"
					vim.fn.mkdir(g, "p")
					local function config(foreground, sync)
						return {
							themes_dir = g,
							theme_file = dir .. "/g-current",
							reload_command = { "echo", "ghostty" },
							debounce_ms = 0,
							sync_on_startup = sync,
							overrides = { elflord = { foreground = foreground } },
						}
					end
					-- Previous session: cache generated under the old override,
					-- the pointer already names the theme.
					local mirror = fresh_require()
					local _, restore_seed = stub_system()
					mirror.setup(config("#111111", false))
					mirror.push("elflord")
					restore_seed()
					-- "Restart": fresh instance, override edited in config, and
					-- sync_on_startup re-applies the pointed-at colorscheme.
					mirror = fresh_require()
					local calls, restore = stub_system()
					mirror.setup(config("#222222", true))
					vim.api.nvim_exec_autocmds("VimEnter", {})
					restore()
					local joined = table.concat(vim.fn.readfile(g .. "/elflord"), "\n")
					assert.is_truthy(joined:find("#222222", 1, true))
					local reloaded = false
					for _, c in ipairs(calls) do
						if c.cmd[2] == "ghostty" then reloaded = true end
					end
					assert.is_true(reloaded)
				end)
			end)
		end)
	end)

	describe("integration: override edit across a restart", function()
		it("startup sync regenerates a stale-stamped cache and reloads tmux", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local g, t = dir .. "/g", dir .. "/t"
					vim.fn.mkdir(g, "p")
					vim.fn.mkdir(t, "p")
					local function config(accent, sync)
						return {
							themes_dir = g,
							theme_file = dir .. "/g-current",
							reload_command = { "echo", "ghostty" },
							debounce_ms = 0,
							sync_on_startup = sync,
							tmux = {
								enabled = true,
								themes_dir = t,
								theme_file = dir .. "/t-current.conf",
								reload_command = { "echo", "tmux" },
								overrides = { elflord = { accent = accent } },
							},
						}
					end
					-- Previous session: cache generated under the old override,
					-- both pointers already name the theme.
					local mirror = fresh_require()
					local _, restore_seed = stub_system()
					mirror.setup(config("#111111", false))
					mirror.push("elflord")
					restore_seed()
					-- "Restart": fresh instance, override edited in config, and
					-- sync_on_startup re-applies the pointed-at colorscheme.
					mirror = fresh_require()
					local calls, restore = stub_system()
					mirror.setup(config("#222222", true))
					vim.api.nvim_exec_autocmds("VimEnter", {})
					restore()
					local joined = table.concat(vim.fn.readfile(t .. "/elflord.conf"), "\n")
					assert.is_truthy(joined:find("#222222", 1, true))
					local reloaded = false
					for _, c in ipairs(calls) do
						if c.cmd[2] == "tmux" then reloaded = true end
					end
					assert.is_true(reloaded)
				end)
			end)
		end)
	end)

	describe("setup: ghostty overrides config", function()
		it("defaults overrides to an empty table", function()
			local mirror = fresh_require()
			mirror.setup()
			assert.same({}, mirror.config.overrides)
		end)

		it("rejects a non-table overrides, naming the field", function()
			local mirror = fresh_require()
			local ok, err = pcall(mirror.setup, { overrides = "nope" })
			assert.is_false(ok)
			assert.is_truthy(tostring(err):find("overrides", 1, true))
		end)

		---Whether a captured WARN notification contains `needle`.
		local function warned(notes, needle)
			for _, n in ipairs(notes) do
				if n.level == vim.log.levels.WARN and n.msg:find(needle, 1, true) then return true end
			end
			return false
		end

		it("notifies on an unknown override param", function()
			with_notify(function(notes, wait)
				local mirror = fresh_require()
				mirror.setup({ overrides = { elflord = { bg = "#fff" } } })
				wait(1)
				assert.is_true(warned(notes, 'unknown ghostty override param "bg"'))
			end)
		end)

		it("does not recognize background as a param (the one color that must not diverge)", function()
			with_notify(function(notes, wait)
				local mirror = fresh_require()
				mirror.setup({ overrides = { elflord = { background = "#101010" } } })
				wait(1)
				assert.is_true(warned(notes, 'unknown ghostty override param "background"'))
			end)
		end)

		it("notifies on an invalid override color value", function()
			with_notify(function(notes, wait)
				local mirror = fresh_require()
				mirror.setup({ overrides = { elflord = { foreground = "nope" } } })
				wait(1)
				assert.is_true(warned(notes, 'invalid ghostty override foreground value "nope"'))
			end)
		end)

		it("notifies on an override keyed by a non-existing colorscheme", function()
			with_notify(function(notes, wait)
				local mirror = fresh_require()
				mirror.setup({ overrides = { no_such_scheme_xyzzy = { foreground = "#fff" } } })
				wait(1)
				assert.is_true(warned(notes, 'ghostty override for "no_such_scheme_xyzzy"'))
			end)
		end)

		it("does not notify for valid overrides, including a light-variant key", function()
			with_notify(function(notes)
				local mirror = fresh_require()
				mirror.setup({
					overrides = {
						elflord = {
							foreground = "#ddd",
							cursor_color = "#ffaabb",
							cursor_text = "#000000",
							selection_background = "#333333",
							selection_foreground = "#ffffff",
						},
						["elflord-light"] = { foreground = "#1a1a1a" },
					},
				})
				vim.wait(50)
				assert.same({}, notes)
			end)
		end)

		it("notifies on a non-table palette override", function()
			with_notify(function(notes, wait)
				local mirror = fresh_require()
				mirror.setup({ overrides = { elflord = { palette = "nope" } } })
				wait(1)
				assert.is_true(warned(notes, 'invalid ghostty override palette value "nope"'))
			end)
		end)

		it("notifies on an out-of-range palette slot", function()
			with_notify(function(notes, wait)
				local mirror = fresh_require()
				mirror.setup({ overrides = { elflord = { palette = { [16] = "#fff" } } } })
				wait(1)
				assert.is_true(warned(notes, 'invalid ghostty override palette slot "16"'))
			end)
		end)

		it("notifies on an invalid palette slot color", function()
			with_notify(function(notes, wait)
				local mirror = fresh_require()
				mirror.setup({ overrides = { elflord = { palette = { [3] = "zzz" } } } })
				wait(1)
				assert.is_true(warned(notes, 'invalid ghostty override palette[3] value "zzz"'))
			end)
		end)

		it("does not notify for a valid palette override", function()
			with_notify(function(notes)
				local mirror = fresh_require()
				mirror.setup({ overrides = { elflord = { palette = { [0] = "#000", [15] = "#ffffff" } } } })
				vim.wait(50)
				assert.same({}, notes)
			end)
		end)
	end)

	describe("setup: tmux override validation", function()
		---Whether a captured WARN notification contains `needle`.
		local function warned(notes, needle)
			for _, n in ipairs(notes) do
				if n.level == vim.log.levels.WARN and n.msg:find(needle, 1, true) then return true end
			end
			return false
		end

		it("notifies on an unknown override param", function()
			with_notify(function(notes, wait)
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true, overrides = { elflord = { acent = "#fff" } } } })
				wait(1)
				assert.is_true(warned(notes, "acent"))
			end)
		end)

		it("notifies on an invalid override value", function()
			with_notify(function(notes, wait)
				local mirror = fresh_require()
				mirror.setup({
					tmux = { enabled = true, overrides = { elflord = { divider = "nope", bar_blend = "half" } } },
				})
				wait(2)
				assert.is_true(warned(notes, 'divider value "nope"'))
				assert.is_true(warned(notes, 'bar_blend value "half"'))
			end)
		end)

		it("notifies on an out-of-range bar_blend", function()
			with_notify(function(notes, wait)
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true, overrides = { elflord = { bar_blend = 7 } } } })
				wait(1)
				assert.is_true(warned(notes, 'bar_blend value "7"'))
			end)
		end)

		it("delivers warnings to a vim.notify replacement installed after setup", function()
			-- Deliberately not with_notify: the point is that setup runs while the
			-- builtin vim.notify is still in place (early in a user config) and a
			-- notifier plugin replacing it later in startup still gets the warning,
			-- instead of the builtin echo blocking on Press ENTER.
			local mirror = fresh_require()
			mirror.setup({ tmux = { enabled = true, overrides = { elflord = { bar_blend = 7 } } } })
			local notes, restore = stub_notify()
			vim.wait(200, function() return #notes > 0 end)
			restore()
			assert.equals(1, #notes)
			assert.is_truthy(notes[1].msg:find('bar_blend value "7"', 1, true))
		end)

		it("notifies on an override keyed by a non-existing colorscheme", function()
			with_notify(function(notes, wait)
				local mirror = fresh_require()
				mirror.setup({ tmux = { enabled = true, overrides = { no_such_scheme_xyzzy = { accent = "#fff" } } } })
				wait(1)
				assert.is_true(warned(notes, "no_such_scheme_xyzzy"))
			end)
		end)

		it("does not notify for valid overrides, including a light-variant key", function()
			with_notify(function(notes)
				local mirror = fresh_require()
				mirror.setup({
					tmux = {
						enabled = true,
						overrides = {
							elflord = { accent = "#fff", divider = "#123456", bar_blend = 0.3 },
							["elflord-light"] = { accent = "#000" },
						},
					},
				})
				vim.wait(50)
				assert.same({}, notes)
			end)
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
					vim.fn.writefile({
						"# Generated by ghostty-mirror.nvim from nvim colorscheme: foo",
						'set -g status-style "bg=#14161b"',
					}, dir .. "/foo.conf")
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

		it("tolerates the pointer vanishing between existence check and read", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/themes"
					vim.fn.mkdir(themes_dir, "p")
					local theme_file = dir .. "/tc.conf"
					-- Simulate the vanish race: any existence check says readable,
					-- but the pointer is gone by the time it's read. The push must
					-- treat it as absent and carry on, not throw E484.
					local real_filereadable = vim.fn.filereadable
					vim.fn.filereadable = function() return 1 end ---@diagnostic disable-line: duplicate-set-field
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({ tmux = { enabled = true, themes_dir = themes_dir, theme_file = theme_file } })
					local ok, err = pcall(mirror.push_tmux, "mytheme")
					vim.fn.filereadable = real_filereadable
					restore()
					assert.is_true(ok, tostring(err))
					assert.equals(1, #calls)
					assert.same({ 'source-file "' .. themes_dir .. '/mytheme.conf"' }, vim.fn.readfile(theme_file))
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

		it("leaves an empty file alone (no marker to match)", function()
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile({}, themes_dir .. "/empty")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir })
				assert.same({}, mirror.clear_cache())
				assert.equals(1, vim.fn.filereadable(themes_dir .. "/empty"))
			end)
		end)

		it("deletes a file that resolve itself generated (marker round-trip)", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local g, t = dir .. "/g", dir .. "/t"
					local mirror = fresh_require()
					mirror.setup({ themes_dir = g, tmux = { enabled = true, themes_dir = t } })
					assert.equals("mytheme", mirror.resolve("mytheme"))
					assert.equals("mytheme", mirror.resolve_tmux("mytheme"))

					local cleared = mirror.clear_cache()

					assert.equals(0, vim.fn.filereadable(g .. "/mytheme"))
					assert.equals(0, vim.fn.filereadable(t .. "/mytheme.conf"))
					assert.is_true(vim.tbl_contains(cleared, "mytheme"))
					assert.is_true(vim.tbl_contains(cleared, "mytheme.conf"))
				end)
			end)
		end)

		it("skips an unreadable file instead of erroring mid-clear", function()
			-- Deterministic stand-in for the TOCTOU race: a file fs_stat sees but
			-- readfile can't open must read as not-generated, not throw E484.
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile(
					{ "# Generated by ghostty-mirror.nvim from nvim colorscheme: gen", "background = #000000" },
					themes_dir .. "/gen"
				)
				vim.fn.writefile({ "secret" }, themes_dir .. "/unreadable")
				vim.fn.setfperm(themes_dir .. "/unreadable", "---------")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir })
				local ok, cleared = pcall(mirror.clear_cache)
				vim.fn.setfperm(themes_dir .. "/unreadable", "rw-------")
				assert.is_true(ok, tostring(cleared))
				assert.same({ "gen" }, cleared)
				assert.equals(1, vim.fn.filereadable(themes_dir .. "/unreadable"))
			end)
		end)

		it("also clears generated tmux theme files, leaving hand-made ones", function()
			with_tmp_dir(function(dir)
				local g, t = dir .. "/g", dir .. "/t"
				vim.fn.mkdir(g, "p")
				vim.fn.mkdir(t, "p")
				vim.fn.writefile({
					"# Generated by ghostty-mirror.nvim from nvim colorscheme: gen",
					'set -g status-style "bg=#000000"',
				}, t .. "/gen.conf")
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

	describe("pull", function()
		---Run fn with the colorscheme saved, restoring it afterwards so the
		---highlight clobber from a real :colorscheme doesn't leak into later specs.
		local function with_colorscheme_restored(fn)
			local before = vim.g.colors_name
			local ok, err = pcall(fn)
			pcall(vim.cmd.colorscheme, before or "default")
			if not ok then error(err) end
		end

		it("applies the colorscheme named in theme_file", function()
			with_tmp_dir(function(dir)
				with_colorscheme_restored(function()
					vim.fn.writefile({ "theme = elflord" }, dir .. "/theme-current")
					local _, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({
						themes_dir = dir,
						theme_file = dir .. "/theme-current",
						generate = false,
						debounce_ms = 0,
					})
					mirror.pull()
					restore()
					assert.equals("elflord", vim.g.colors_name)
				end)
			end)
		end)

		it("falls back to the base scheme under a light background for a generated light-variant name", function()
			with_tmp_dir(function(dir)
				with_colorscheme_restored(function()
					local bg = vim.o.background
					vim.fn.writefile({ "theme = default-light" }, dir .. "/theme-current")
					local _, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({
						themes_dir = dir,
						theme_file = dir .. "/theme-current",
						generate = false,
						debounce_ms = 0,
					})
					mirror.pull()
					restore()
					local got, got_bg = vim.g.colors_name, vim.o.background
					vim.o.background = bg
					assert.equals("default", got)
					assert.equals("light", got_bg)
				end)
			end)
		end)

		it("warns and restores the background when neither the variant nor its base is installed", function()
			with_tmp_dir(function(dir)
				local before, bg = vim.g.colors_name, vim.o.background
				vim.fn.writefile({ "theme = ghostty-mirror-nope-light" }, dir .. "/theme-current")
				local notices, restore = stub_notify()
				local mirror = fresh_require()
				mirror.setup({ themes_dir = dir, theme_file = dir .. "/theme-current", generate = false })
				mirror.pull()
				restore()
				assert.equals(before, vim.g.colors_name)
				assert.equals(bg, vim.o.background)
				assert.equals(1, #notices)
				assert.equals(vim.log.levels.WARN, notices[1].level)
				assert.is_truthy(notices[1].msg:find("ghostty-mirror-nope-light", 1, true))
			end)
		end)

		it("warns and keeps the current colorscheme when the named scheme is not installed", function()
			with_tmp_dir(function(dir)
				local before = vim.g.colors_name
				vim.fn.writefile({ "theme = ghostty-mirror-nope-xyzzy" }, dir .. "/theme-current")
				local notices, restore = stub_notify()
				local mirror = fresh_require()
				mirror.setup({ themes_dir = dir, theme_file = dir .. "/theme-current", generate = false })
				local ok = pcall(mirror.pull)
				restore()
				assert.is_true(ok)
				assert.equals(before, vim.g.colors_name)
				assert.equals(1, #notices)
				assert.equals(vim.log.levels.WARN, notices[1].level)
				assert.is_truthy(notices[1].msg:find("ghostty-mirror-nope-xyzzy", 1, true))
			end)
		end)

		it("warns and keeps the current colorscheme when theme_file is unreadable", function()
			with_tmp_dir(function(dir)
				local before = vim.g.colors_name
				local notices = {}
				local orig_notify = vim.notify
				vim.notify = function(msg, level) table.insert(notices, { msg = msg, level = level }) end ---@diagnostic disable-line: duplicate-set-field
				local mirror = fresh_require()
				mirror.setup({ theme_file = dir .. "/missing", generate = false })
				mirror.pull()
				vim.notify = orig_notify
				assert.equals(before, vim.g.colors_name)
				assert.equals(1, #notices)
				assert.equals(vim.log.levels.WARN, notices[1].level)
				assert.is_truthy(notices[1].msg:find(dir .. "/missing", 1, true))
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

		it("returns nil when the named theme fails the name guard", function()
			with_tmp_dir(function(dir)
				local theme_file = dir .. "/theme-current"
				vim.fn.writefile({ "theme = ../../../tmp/payload" }, theme_file)
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

		it("finds the theme directive even when it is not the first line", function()
			with_tmp_dir(function(dir)
				local theme_file = dir .. "/theme-current"
				vim.fn.writefile({ "# a comment", "", "theme = bar" }, theme_file)
				local mirror = fresh_require()
				mirror.setup({ theme_file = theme_file })
				assert.equals("bar", mirror.read_current())
			end)
		end)

		it("returns nil when the file vanishes between existence check and read", function()
			with_tmp_dir(function(dir)
				-- Simulate the vanish race: any existence check says readable, but
				-- the file is gone by the time it's read. Must read as absent, not
				-- throw E484 into pull / the FocusGained callback.
				local real_filereadable = vim.fn.filereadable
				vim.fn.filereadable = function() return 1 end ---@diagnostic disable-line: duplicate-set-field
				local mirror = fresh_require()
				mirror.setup({ theme_file = dir .. "/vanished" })
				local ok, result = pcall(mirror.read_current)
				vim.fn.filereadable = real_filereadable
				assert.is_true(ok, tostring(result))
				assert.is_nil(result)
			end)
		end)

		it("picks the first directive when multiple theme lines exist", function()
			with_tmp_dir(function(dir)
				local theme_file = dir .. "/theme-current"
				vim.fn.writefile({ "theme = first", "theme = second" }, theme_file)
				local mirror = fresh_require()
				mirror.setup({ theme_file = theme_file })
				assert.equals("first", mirror.read_current())
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

	describe("setup: version floor", function()
		it("refuses to set up on Neovim older than 0.10, notifying an error", function()
			-- fresh_require first: it setup()s the outgoing instance, which must
			-- not see the has/notify stubs below.
			local mirror = fresh_require()
			local notices = {}
			local orig_notify, orig_has = vim.notify, vim.fn.has
			vim.notify = function(msg, level) table.insert(notices, { msg = msg, level = level }) end ---@diagnostic disable-line: duplicate-set-field
			vim.fn.has = function(feat) ---@diagnostic disable-line: duplicate-set-field
				if feat == "nvim-0.10" then return 0 end
				return orig_has(feat)
			end
			local ok, err = pcall(mirror.setup, { debounce_ms = 5 })
			vim.notify, vim.fn.has = orig_notify, orig_has
			assert.is_true(ok, err)
			assert.are_not.equals(5, mirror.config.debounce_ms)
			assert.equals(1, #notices)
			assert.equals(vim.log.levels.ERROR, notices[1].level)
			assert.is_truthy(notices[1].msg:find("0.10", 1, true))
		end)
	end)

	describe("setup: config validation", function()
		it("rejects a non-table tmux option with a clear error", function()
			local mirror = fresh_require()
			local ok, err = pcall(mirror.setup, { tmux = true })
			assert.is_false(ok)
			assert.is_truthy(tostring(err):find("tmux", 1, true))
		end)

		it("rejects a wrongly-typed scalar option, naming the field", function()
			local mirror = fresh_require()
			local ok, err = pcall(mirror.setup, { debounce_ms = "fast" })
			assert.is_false(ok)
			assert.is_truthy(tostring(err):find("debounce_ms", 1, true))
		end)

		it("rejects a wrongly-typed tmux sub-option, naming the field", function()
			local mirror = fresh_require()
			local ok, err = pcall(mirror.setup, { tmux = { enabled = "yes" } })
			assert.is_false(ok)
			assert.is_truthy(tostring(err):find("tmux.enabled", 1, true))
		end)

		it("rejects a non-table tmux.overrides, naming the field", function()
			local mirror = fresh_require()
			local ok, err = pcall(mirror.setup, { tmux = { overrides = "nope" } })
			assert.is_false(ok)
			assert.is_truthy(tostring(err):find("tmux.overrides", 1, true))
		end)

		it("accepts light_variant_suffix = false as the disable sentinel", function()
			local mirror = fresh_require()
			mirror.setup({ light_variant_suffix = false })
			assert.equals(false, mirror.config.light_variant_suffix)
		end)

		it("rejects tmux paths carrying quotes, backslashes or newlines, naming the field", function()
			-- tmux.themes_dir is interpolated into the quoted `source-file "..."`
			-- line in a file tmux executes; a quote or newline escapes the quoting,
			-- and tmux interprets backslash escapes inside the double quotes, so a
			-- backslash silently mangles the path.
			for _, field in ipairs({ "themes_dir", "theme_file" }) do
				for _, bad in ipairs({ '/tmp/x"y', "/tmp/x\ny", "/tmp/x\\y" }) do
					local mirror = fresh_require()
					local ok, err = pcall(mirror.setup, { tmux = { [field] = bad } })
					assert.is_false(ok, ("tmux.%s %q was accepted"):format(field, bad))
					assert.is_truthy(tostring(err):find("tmux." .. field, 1, true))
				end
			end
		end)

		it("rejects a light_variant_suffix carrying path or quoting characters, naming the field", function()
			-- The suffix is appended to an already-validated colorscheme name and
			-- flows into file paths and the Ghostty/tmux pointer lines, so it must
			-- pass the same character class as the name itself.
			for _, suffix in ipairs({ "/evil", "\ncommand = oops", '"', "-li ght" }) do
				local mirror = fresh_require()
				local ok, err = pcall(mirror.setup, { light_variant_suffix = suffix })
				assert.is_false(ok, ("suffix %q was accepted"):format(suffix))
				assert.is_truthy(tostring(err):find("light_variant_suffix", 1, true))
			end
		end)
	end)

	describe("setup: idempotent re-setup", function()
		it("re-setup restores a default mutated through an omitted-key subtable", function()
			local mirror = fresh_require()
			mirror.setup({ debounce_ms = 0 })
			mirror.config.tmux.bar_blend = 0.9
			mirror.setup({ debounce_ms = 0 })
			assert.equals(0.22, mirror.config.tmux.bar_blend)
		end)

		it("cancels a pending debounced push from a prior setup", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")
				vim.fn.writefile({ "" }, themes_dir .. "/elflord")

				local calls, restore = stub_system()
				local mirror = fresh_require()
				local opts = {
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo" },
					debounce_ms = 40,
				}
				mirror.setup(opts)
				vim.cmd.colorscheme("elflord")
				mirror.setup(opts)
				vim.wait(200, function() return #calls > 0 end)
				restore()

				assert.equals(0, #calls)
				assert.equals(0, vim.fn.filereadable(theme_file))
			end)
		end)
		it("cancels a pending debounced push on VimLeavePre", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")
				vim.fn.writefile({ "" }, themes_dir .. "/elflord")

				local calls, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo" },
					debounce_ms = 40,
				})
				vim.cmd.colorscheme("elflord")
				vim.api.nvim_exec_autocmds("VimLeavePre", { group = "ghostty-mirror" })
				vim.wait(200, function() return #calls > 0 end)
				restore()

				assert.equals(0, #calls)
				assert.equals(0, vim.fn.filereadable(theme_file))
			end)
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

		it("a debounced push also mirrors only the settled scheme to tmux", function()
			with_tmp_dir(function(dir)
				local g, t = dir .. "/g", dir .. "/t"
				vim.fn.mkdir(g, "p")
				vim.fn.mkdir(t, "p")
				for _, n in ipairs({ "elflord", "habamax", "default" }) do
					vim.fn.writefile({ "" }, g .. "/" .. n)
					vim.fn.writefile({ "" }, t .. "/" .. n .. ".conf")
				end

				local calls, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = g,
					theme_file = dir .. "/g-current",
					reload_command = { "echo" },
					debounce_ms = 40,
					tmux = {
						enabled = true,
						themes_dir = t,
						theme_file = dir .. "/t-current.conf",
						reload_command = { "echo" },
					},
				})
				vim.cmd.colorscheme("elflord")
				vim.cmd.colorscheme("habamax")
				vim.cmd.colorscheme("default")
				assert.equals(0, #calls)
				vim.wait(400, function() return #calls >= 2 end)
				restore()

				-- one Ghostty reload + one tmux source for the settled scheme only
				assert.equals(2, #calls)
				assert.same({ "theme = default" }, vim.fn.readfile(dir .. "/g-current"))
				assert.same({ 'source-file "' .. t .. '/default.conf"' }, vim.fn.readfile(dir .. "/t-current.conf"))
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
				mirror.setup({
					themes_dir = dir .. "/themes",
					theme_file = dir .. "/theme-current",
					reload_command = { "echo" },
				})
				local d = fresh_health().diagnostics()
				local errors = vim.tbl_filter(function(e) return e.status == "error" end, d)
				assert.same({}, errors)
			end)
		end)

		it("flags unwritable themes_dir and theme_file as errors", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir .. "/missing/parent/themes",
					theme_file = dir .. "/missing/parent/theme-current",
					reload_command = { "echo" },
				})
				local d = fresh_health().diagnostics()
				local function status_of(needle)
					for _, e in ipairs(d) do
						if e.msg:find(needle, 1, true) then return e.status end
					end
				end
				assert.equals("error", status_of("themes_dir not writable"))
				assert.equals("error", status_of("theme_file not writable"))
			end)
		end)

		it("flags an unresolvable reload command as an error", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir,
					theme_file = dir .. "/theme-current",
					reload_command = { "ghostty-mirror-nope-xyzzy" },
				})
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

	describe("push: skip when unchanged", function()
		it("skips the write and reload when the pointer already names the resolved theme", function()
			with_tmp_dir(function(dir)
				local themes_dir, theme_file = dir .. "/themes", dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")
				vim.fn.writefile({ "" }, themes_dir .. "/foo")
				vim.fn.writefile({ "theme = foo" }, theme_file)
				local calls, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir, theme_file = theme_file, reload_command = { "echo" } })
				mirror.push("foo")
				restore()
				assert.equals(0, #calls)
			end)
		end)

		it("writes and reloads when the resolved theme differs from the pointer", function()
			with_tmp_dir(function(dir)
				local themes_dir, theme_file = dir .. "/themes", dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")
				vim.fn.writefile({ "" }, themes_dir .. "/foo")
				vim.fn.writefile({ "theme = old" }, theme_file)
				local calls, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir, theme_file = theme_file, reload_command = { "echo" } })
				mirror.push("foo")
				restore()
				assert.equals(1, #calls)
				assert.same({ "theme = foo" }, vim.fn.readfile(theme_file))
			end)
		end)

		it("force writes and reloads even when the pointer is unchanged", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir, theme_file = dir .. "/themes", dir .. "/theme-current"
					vim.fn.mkdir(themes_dir, "p")
					vim.fn.writefile({ "theme = mytheme" }, theme_file)
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, theme_file = theme_file, reload_command = { "echo" } })
					mirror.push("mytheme", { force = true })
					restore()
					assert.equals(1, #calls)
				end)
			end)
		end)

		it("skips the tmux source and reload when the tmux pointer is unchanged", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local g, t = dir .. "/g", dir .. "/t"
					vim.fn.mkdir(g, "p")
					vim.fn.mkdir(t, "p")
					vim.fn.writefile({ "" }, g .. "/mytheme")
					vim.fn.writefile({ "theme = mytheme" }, dir .. "/g-current")
					vim.fn.writefile({ "" }, t .. "/mytheme.conf")
					vim.fn.writefile({ 'source-file "' .. t .. '/mytheme.conf"' }, dir .. "/t-current.conf")
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({
						themes_dir = g,
						theme_file = dir .. "/g-current",
						reload_command = { "echo" },
						tmux = {
							enabled = true,
							themes_dir = t,
							theme_file = dir .. "/t-current.conf",
							reload_command = { "echo" },
						},
					})
					mirror.push("mytheme")
					restore()
					assert.equals(0, #calls)
				end)
			end)
		end)
	end)

	describe("manage_background", function()
		it("brings an adaptive scheme back to dark after a light background", function()
			with_tmp_dir(function(dir)
				local saved = vim.o.background
				local _, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir,
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					generate = false,
					debounce_ms = 0,
					manage_background = true,
				})
				vim.o.background = "light"
				vim.cmd.colorscheme("default")
				assert.equals("dark", vim.o.background)
				restore()
				vim.o.background = saved
			end)
		end)

		it("syncs &background to light for a scheme whose Normal is light", function()
			with_tmp_dir(function(dir)
				local saved = vim.o.background
				local _, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir,
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					generate = false,
					debounce_ms = 0,
					manage_background = true,
				})
				vim.o.background = "dark"
				vim.api.nvim_set_hl(0, "Normal", { fg = 0x000000, bg = 0xeeeeee })
				vim.api.nvim_exec_autocmds("ColorScheme", { group = "ghostty-mirror", pattern = "fake" })
				assert.equals("light", vim.o.background)
				restore()
				vim.o.background = saved
			end)
		end)

		it("does not touch &background when disabled (default)", function()
			with_tmp_dir(function(dir)
				local saved = vim.o.background
				local _, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir,
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					generate = false,
					debounce_ms = 0,
				})
				vim.o.background = "light"
				vim.api.nvim_set_hl(0, "Normal", { bg = 0x111111 })
				vim.api.nvim_exec_autocmds("ColorScheme", { group = "ghostty-mirror", pattern = "fake" })
				assert.equals("light", vim.o.background)
				restore()
				vim.o.background = saved
			end)
		end)
	end)

	describe("manage_background + palette", function()
		it("keeps the scheme palette when the &background sync re-applies the scheme", function()
			with_tmp_dir(function(dir)
				-- a real, loadable light scheme that owns a full terminal palette but does
				-- not set &background itself (like cyberdream-light)
				local rtp = dir .. "/rtp"
				vim.fn.mkdir(rtp .. "/colors", "p")
				vim.fn.writefile({
					'vim.g.colors_name = "gm_testlight"',
					'for i = 0, 15 do vim.g["terminal_color_" .. i] = string.format("#%02xabcd", i) end',
					'vim.api.nvim_set_hl(0, "Normal", { fg = 0x222222, bg = 0xeeeeee })',
				}, rtp .. "/colors/gm_testlight.lua")
				vim.opt.runtimepath:prepend(rtp)
				local saved_bg = vim.o.background
				local saved_pal = {}
				for i = 0, 15 do
					saved_pal[i] = vim.g["terminal_color_" .. i]
					vim.g["terminal_color_" .. i] = nil
				end
				local calls, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir .. "/themes",
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					debounce_ms = 0,
					manage_background = true,
				})
				vim.o.background = "dark"
				vim.cmd.colorscheme("gm_testlight")
				restore()
				vim.opt.runtimepath:remove(rtp)
				assert.equals("light", vim.o.background)
				local name = mirror.read_current()
				assert.is_not_nil(name)
				local body = table.concat(vim.fn.readfile(dir .. "/themes/" .. name), "\n")
				assert.is_truthy(body:find("palette = 0=", 1, true))
				assert.equals(1, #calls)
				for i = 0, 15 do
					vim.g["terminal_color_" .. i] = saved_pal[i]
				end
				vim.o.background = saved_bg
			end)
		end)
	end)

	describe("manage_background + tmux", function()
		it("the &background sync leaves Ghostty and tmux pointing at the same theme", function()
			with_tmp_dir(function(dir)
				-- a real, loadable light scheme that does not set &background itself
				local rtp = dir .. "/rtp"
				vim.fn.mkdir(rtp .. "/colors", "p")
				vim.fn.writefile({
					'vim.g.colors_name = "gm_tmuxlight"',
					'vim.api.nvim_set_hl(0, "Normal", { fg = 0x222222, bg = 0xeeeeee })',
				}, rtp .. "/colors/gm_tmuxlight.lua")
				vim.opt.runtimepath:prepend(rtp)
				local saved_bg = vim.o.background
				local calls, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir .. "/g",
					theme_file = dir .. "/g-current",
					reload_command = { "echo" },
					debounce_ms = 0,
					manage_background = true,
					tmux = {
						enabled = true,
						themes_dir = dir .. "/t",
						theme_file = dir .. "/t-current.conf",
						reload_command = { "echo" },
					},
				})
				vim.o.background = "dark"
				vim.cmd.colorscheme("gm_tmuxlight")
				restore()
				vim.opt.runtimepath:remove(rtp)
				assert.equals("light", vim.o.background)
				assert.equals(2, #calls) -- one Ghostty reload + one tmux source
				local name = mirror.read_current()
				assert.is_not_nil(name)
				local pointer = vim.fn.readfile(dir .. "/t-current.conf")[1]
				assert.equals(('source-file "%s/t/%s.conf"'):format(dir, name), pointer)
				assert.equals(1, vim.fn.filereadable(("%s/t/%s.conf"):format(dir, name)))
				vim.o.background = saved_bg
			end)
		end)
	end)

	describe("push: empty scheme", function()
		it("push is a no-op for an empty colorscheme name", function()
			with_tmp_dir(function(dir)
				local themes_dir, theme_file = dir .. "/themes", dir .. "/tc"
				vim.fn.mkdir(themes_dir, "p")
				local calls, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir, theme_file = theme_file, reload_command = { "echo" } })
				assert.is_nil(mirror.push(""))
				restore()
				assert.equals(0, #calls)
				assert.equals(0, vim.fn.filereadable(theme_file))
			end)
		end)

		it("push_tmux is a no-op for an empty colorscheme name", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local t = dir .. "/t"
					vim.fn.mkdir(t, "p")
					local calls, restore = stub_system()
					local mirror = fresh_require()
					mirror.setup({
						tmux = {
							enabled = true,
							themes_dir = t,
							theme_file = dir .. "/tc.conf",
							reload_command = { "echo" },
						},
					})
					assert.is_nil(mirror.push_tmux(""))
					restore()
					assert.equals(0, #calls)
				end)
			end)
		end)
	end)

	describe("sync_on_startup", function()
		it("applies the theme named in theme_file on setup", function()
			with_tmp_dir(function(dir)
				local theme_file = dir .. "/tc"
				vim.fn.writefile({ "theme = elflord" }, theme_file)
				local _, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir .. "/themes",
					theme_file = theme_file,
					reload_command = { "echo" },
					generate = false,
					debounce_ms = 0,
					sync_on_startup = true,
				})
				vim.api.nvim_exec_autocmds("VimEnter", {})
				restore()
				assert.equals("elflord", vim.g.colors_name)
			end)
		end)

		it("applies the theme immediately when setup runs after VimEnter", function()
			with_tmp_dir(function(dir)
				vim.fn.writefile({ "theme = elflord" }, dir .. "/tc")
				local rtp_root =
					vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("lua/ghostty-mirror/init.lua", false)[1], ":h:h:h")
				-- +cmds run before VimEnter, so reach the immediate branch by calling
				-- setup from inside a VimEnter callback: v:vim_did_enter is already 1
				-- there, and a deferred VimEnter autocmd registered during the event
				-- would never fire — only the immediate branch can pass this test.
				local script = dir .. "/setup.lua"
				vim.fn.writefile({
					'vim.api.nvim_create_autocmd("VimEnter", {',
					"	callback = function()",
					'		assert(vim.v.vim_did_enter == 1, "expected to run after VimEnter")',
					'		require("ghostty-mirror").setup({',
					("			themes_dir = %q,"):format(dir .. "/themes"),
					("			theme_file = %q,"):format(dir .. "/tc"),
					'			reload_command = { "true" },',
					"			generate = false,",
					"			sync_on_startup = true,",
					"		})",
					('		vim.fn.writefile({ vim.g.colors_name or "" }, %q)'):format(dir .. "/out"),
					"		vim.cmd.quitall()",
					"	end,",
					"})",
				}, script)
				vim.fn.system({
					vim.v.progpath,
					"--headless",
					"--clean",
					"--cmd",
					"set rtp+=" .. rtp_root,
					"--cmd",
					"luafile " .. script,
				})
				assert.same({ "elflord" }, vim.fn.readfile(dir .. "/out"))
			end)
		end)

		it("keeps the current colorscheme when theme_file names an uninstalled scheme", function()
			with_tmp_dir(function(dir)
				vim.cmd.colorscheme("default")
				vim.fn.writefile({ "theme = ghostty-mirror-nope-xyzzy" }, dir .. "/tc")
				local _, restore_system = stub_system()
				local _, restore_notify = stub_notify()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir .. "/themes",
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					generate = false,
					debounce_ms = 0,
					sync_on_startup = true,
				})
				vim.api.nvim_exec_autocmds("VimEnter", {})
				restore_system()
				restore_notify()
				assert.equals("default", vim.g.colors_name)
			end)
		end)

		it("does not apply any theme on setup by default", function()
			with_tmp_dir(function(dir)
				vim.cmd.colorscheme("default")
				local _, restore = stub_system()
				vim.fn.writefile({ "theme = elflord" }, dir .. "/tc")
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir .. "/themes",
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					generate = false,
					debounce_ms = 0,
				})
				restore()
				assert.equals("default", vim.g.colors_name)
			end)
		end)
	end)

	describe("sync_on_focus", function()
		it("applies the theme_file theme on FocusGained when it differs from the loaded one", function()
			with_tmp_dir(function(dir)
				local _, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir .. "/themes",
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					generate = false,
					debounce_ms = 0,
					sync_on_focus = true,
				})
				vim.cmd.colorscheme("default")
				vim.fn.writefile({ "theme = elflord" }, dir .. "/tc")
				vim.api.nvim_exec_autocmds("FocusGained", {})
				restore()
				assert.equals("elflord", vim.g.colors_name)
			end)
		end)

		it("re-enters the mirror chain, so the synced scheme becomes current_scheme", function()
			with_tmp_dir(function(dir)
				local _, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir .. "/themes",
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					generate = false,
					debounce_ms = 0,
					sync_on_focus = true,
				})
				vim.cmd.colorscheme("default")
				vim.fn.writefile({ "theme = elflord" }, dir .. "/tc")
				vim.api.nvim_exec_autocmds("FocusGained", {})
				restore()
				assert.equals("elflord", mirror.current_scheme())
			end)
		end)

		it("applies a generated light-variant name via its base scheme on FocusGained", function()
			with_tmp_dir(function(dir)
				local bg = vim.o.background
				local _, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir .. "/themes",
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					generate = false,
					debounce_ms = 0,
					sync_on_focus = true,
				})
				vim.o.background = "dark"
				vim.cmd.colorscheme("default")
				vim.fn.writefile({ "theme = default-light" }, dir .. "/tc")
				vim.api.nvim_exec_autocmds("FocusGained", {})
				restore()
				local got, got_bg = vim.g.colors_name, vim.o.background
				vim.o.background = bg
				assert.equals("default", got)
				assert.equals("light", got_bg)
			end)
		end)

		it("does not re-apply on a later focus once synced to a light variant", function()
			with_tmp_dir(function(dir)
				local bg = vim.o.background
				local _, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir .. "/themes",
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					generate = false,
					debounce_ms = 0,
					sync_on_focus = true,
				})
				vim.o.background = "dark"
				vim.cmd.colorscheme("default")
				vim.fn.writefile({ "theme = default-light" }, dir .. "/tc")
				vim.api.nvim_exec_autocmds("FocusGained", {})
				local reapplied = 0
				local au = vim.api.nvim_create_autocmd("ColorScheme", {
					callback = function() reapplied = reapplied + 1 end,
				})
				vim.api.nvim_exec_autocmds("FocusGained", {})
				vim.api.nvim_del_autocmd(au)
				restore()
				vim.o.background = bg
				assert.equals(0, reapplied)
			end)
		end)

		it("keeps the current colorscheme when theme_file names an uninstalled scheme", function()
			with_tmp_dir(function(dir)
				local _, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir .. "/themes",
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					generate = false,
					debounce_ms = 0,
					sync_on_focus = true,
				})
				vim.cmd.colorscheme("default")
				vim.fn.writefile({ "theme = ghostty-mirror-nope-xyzzy" }, dir .. "/tc")
				vim.api.nvim_exec_autocmds("FocusGained", {})
				restore()
				assert.equals("default", vim.g.colors_name)
			end)
		end)

		it("does nothing on FocusGained by default", function()
			with_tmp_dir(function(dir)
				local _, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir .. "/themes",
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					generate = false,
					debounce_ms = 0,
				})
				vim.cmd.colorscheme("default")
				vim.fn.writefile({ "theme = elflord" }, dir .. "/tc")
				vim.api.nvim_exec_autocmds("FocusGained", {})
				restore()
				assert.equals("default", vim.g.colors_name)
			end)
		end)
	end)

	describe("plugin auto-setup", function()
		it("sources setup once, guarded by g:loaded_ghostty_mirror", function()
			local plugin_file = vim.fn.fnamemodify(
				vim.api.nvim_get_runtime_file("lua/ghostty-mirror/init.lua", false)[1],
				":h:h:h"
			) .. "/plugin/ghostty-mirror.lua"
			local saved = vim.g.loaded_ghostty_mirror
			local mirror = fresh_require()
			local original = mirror.setup
			local count = 0
			mirror.setup = function() count = count + 1 end ---@diagnostic disable-line: duplicate-set-field
			vim.g.loaded_ghostty_mirror = nil
			vim.cmd.source(plugin_file)
			assert.equals(1, count)
			assert.is_true(vim.g.loaded_ghostty_mirror)
			vim.cmd.source(plugin_file)
			assert.equals(1, count)
			mirror.setup = original
			vim.g.loaded_ghostty_mirror = saved
		end)
	end)

	describe("health: config-file include", function()
		local function fresh_health()
			package.loaded["ghostty-mirror.health"] = nil
			return require("ghostty-mirror.health")
		end

		---Set up a mirror + health pair where the Ghostty config candidates are
		---pinned to dir/config, and theme_file to dir/theme-current.
		local function with_health(dir, config_lines)
			local mirror = fresh_require()
			mirror.setup({ themes_dir = dir, theme_file = dir .. "/theme-current", reload_command = { "echo" } })
			if config_lines then vim.fn.writefile(config_lines, dir .. "/config") end
			local h = fresh_health()
			h.ghostty_config_paths = function() return { dir .. "/config" } end
			return h
		end

		---The include diagnostic entry, if any.
		local function include_entry(h)
			for _, e in ipairs(h.diagnostics()) do
				if e.msg:find("config-file", 1, true) or e.msg:find("included", 1, true) then return e end
			end
		end

		it("reports ok when the config includes theme_file via config-file", function()
			with_tmp_dir(function(dir)
				local h = with_health(dir, { "config-file = ?" .. dir .. "/theme-current" })
				local e = include_entry(h)
				assert.is_not_nil(e)
				assert.equals("ok", e.status)
			end)
		end)

		it("accepts an include without the optional-? prefix and with extra whitespace", function()
			with_tmp_dir(function(dir)
				local h = with_health(dir, { "  config-file   =   " .. dir .. "/theme-current  " })
				assert.equals("ok", include_entry(h).status)
			end)
		end)

		it("resolves an include relative to the config's own directory", function()
			with_tmp_dir(function(dir)
				local h = with_health(dir, { "config-file = ?theme-current" })
				assert.equals("ok", include_entry(h).status)
			end)
		end)

		it("accepts a double-quoted include value", function()
			with_tmp_dir(function(dir)
				local h = with_health(dir, { 'config-file = "' .. dir .. '/theme-current"' })
				assert.equals("ok", include_entry(h).status)
			end)
		end)

		it("warns with the exact line to add when the config lacks the include", function()
			with_tmp_dir(function(dir)
				local h = with_health(dir, { "font-family = monospace" })
				local e = include_entry(h)
				assert.equals("warn", e.status)
				assert.is_truthy(e.msg:find("config-file = ?" .. dir .. "/theme-current", 1, true))
			end)
		end)

		it("warns when no Ghostty config exists at any candidate path", function()
			with_tmp_dir(function(dir)
				local h = with_health(dir, nil)
				local e = include_entry(h)
				assert.equals("warn", e.status)
				assert.is_truthy(e.msg:find("no Ghostty config found", 1, true))
			end)
		end)

		it("does not count a commented-out include", function()
			with_tmp_dir(function(dir)
				local h = with_health(dir, { "# config-file = ?" .. dir .. "/theme-current" })
				assert.equals("warn", include_entry(h).status)
			end)
		end)

		it("refuses a FIFO planted at the config path without blocking", function()
			with_tmp_dir(function(dir)
				vim.system({ "mkfifo", dir .. "/config" }):wait()
				local h = with_health(dir, nil)
				local e = include_entry(h)
				assert.equals("warn", e.status)
			end)
		end)

		it("does not parse an include past the read cap of an oversized config", function()
			with_tmp_dir(function(dir)
				local lines = {}
				for _ = 1, 8192 do
					table.insert(lines, "# " .. string.rep("x", 30))
				end
				table.insert(lines, "config-file = ?" .. dir .. "/theme-current")
				local h = with_health(dir, lines)
				assert.equals("warn", include_entry(h).status)
			end)
		end)

		it("finds the include in a later candidate config when the first lacks it", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({ themes_dir = dir, theme_file = dir .. "/theme-current", reload_command = { "echo" } })
				vim.fn.writefile({ "font-family = monospace" }, dir .. "/config-a")
				vim.fn.writefile({ "config-file = ?" .. dir .. "/theme-current" }, dir .. "/config-b")
				local h = fresh_health()
				h.ghostty_config_paths = function() return { dir .. "/config-a", dir .. "/config-b" } end
				local e = include_entry(h)
				assert.equals("ok", e.status)
				assert.is_truthy(e.msg:find(dir .. "/config-b", 1, true))
			end)
		end)
	end)

	describe("health: tmux", function()
		local function fresh_health()
			package.loaded["ghostty-mirror.health"] = nil
			return require("ghostty-mirror.health")
		end

		---The first diagnostic whose message contains `needle`.
		local function entry(h, needle)
			for _, e in ipairs(h.diagnostics()) do
				if e.msg:find(needle, 1, true) then return e end
			end
		end

		it("reports ok for writable tmux paths when mirroring is enabled", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir,
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					tmux = { enabled = true, themes_dir = dir .. "/tmux-themes", theme_file = dir .. "/tmux.conf" },
				})
				local h = fresh_health()
				assert.equals("ok", entry(h, "tmux themes_dir writable").status)
				assert.equals("ok", entry(h, "tmux theme_file writable").status)
			end)
		end)

		it("flags unwritable tmux paths as errors", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir,
					theme_file = dir .. "/tc",
					reload_command = { "echo" },
					tmux = {
						enabled = true,
						themes_dir = dir .. "/missing/parent/themes",
						theme_file = dir .. "/missing/parent/tmux.conf",
					},
				})
				local h = fresh_health()
				assert.equals("error", entry(h, "tmux themes_dir not writable").status)
				assert.equals("error", entry(h, "tmux theme_file not writable").status)
			end)
		end)

		---Run fn with $PATH pinned, so the executable() checks don't depend on
		---whether the machine running the suite actually has tmux installed.
		local function with_path(path, fn)
			local saved = vim.env.PATH
			vim.env.PATH = path
			local ok, err = pcall(fn)
			vim.env.PATH = saved
			if not ok then error(err) end
		end

		it("reports ok when tmux is on PATH", function()
			with_tmp_dir(function(dir)
				local bin = dir .. "/bin"
				vim.fn.mkdir(bin, "p")
				vim.fn.writefile({ "#!/bin/sh" }, bin .. "/tmux")
				vim.fn.setfperm(bin .. "/tmux", "rwxr-xr-x")
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir,
					theme_file = dir .. "/tc",
					tmux = { enabled = true, themes_dir = dir, theme_file = dir .. "/tmux.conf" },
				})
				local h = fresh_health()
				with_path(bin, function() assert.equals("ok", entry(h, "tmux found on PATH").status) end)
			end)
		end)

		it("warns when tmux mirroring is enabled but tmux is not on PATH", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = dir,
					theme_file = dir .. "/tc",
					tmux = { enabled = true, themes_dir = dir, theme_file = dir .. "/tmux.conf" },
				})
				local h = fresh_health()
				with_path(dir, function() assert.equals("warn", entry(h, "tmux is not on PATH").status) end)
			end)
		end)

		it("reports an info line when tmux mirroring is disabled", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({ themes_dir = dir, theme_file = dir .. "/tc", reload_command = { "echo" } })
				local h = fresh_health()
				assert.equals("info", entry(h, "tmux mirroring disabled").status)
				assert.is_nil(entry(h, "tmux themes_dir"))
			end)
		end)
	end)

	describe("health: ghostty process", function()
		local function fresh_health()
			package.loaded["ghostty-mirror.health"] = nil
			return require("ghostty-mirror.health")
		end

		it("warns when no Ghostty process is running", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({ themes_dir = dir, theme_file = dir .. "/tc", reload_command = { "echo" } })
				local h = fresh_health()
				h.ghostty_running = function() return false end
				local found = false
				for _, e in ipairs(h.diagnostics()) do
					if e.status == "warn" and e.msg:find("Ghostty", 1, true) then found = true end
				end
				assert.is_true(found)
			end)
		end)

		it("reports ok when a Ghostty process is running", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({ themes_dir = dir, theme_file = dir .. "/tc", reload_command = { "echo" } })
				local h = fresh_health()
				h.ghostty_running = function() return true end
				local found = false
				for _, e in ipairs(h.diagnostics()) do
					if e.status == "ok" and e.msg:find("Ghostty", 1, true) then found = true end
				end
				assert.is_true(found)
			end)
		end)

		it("reports info, not a warning, when the check itself is unavailable", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({ themes_dir = dir, theme_file = dir .. "/tc", reload_command = { "echo" } })
				local h = fresh_health()
				h.ghostty_running = function() return nil end
				local found = false
				for _, e in ipairs(h.diagnostics()) do
					if e.status == "info" and e.msg:find("could not check", 1, true) then found = true end
				end
				assert.is_true(found)
			end)
		end)
	end)
end)
