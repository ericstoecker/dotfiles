local M = {}

--- Parses the current line to determine if the cursor is on a
--- package declaration or an import statement's package portion.
--- Returns the package name string if yes, nil if no.
local function detect_package_on_line()
	local line = vim.api.nvim_get_current_line()

	-- Match: package com.demo.user;
	local pkg_decl = line:match("^%s*package%s+([%w%.]+)%s*;")
	if pkg_decl then
		return pkg_decl
	end

	-- Match: import com.demo.user.*;  (wildcard import)
	local wildcard = line:match("^%s*import%s+([%w%.]+)%.%*%s*;")
	if wildcard then
		return wildcard
	end

	-- Match: import com.demo.user.UserDto;
	-- Match: import static com.demo.user.UserDto.someMethod;
	-- Strip uppercase-initial segments (class names / members).
	local import_path = line:match("^%s*import%s+static%s+([%w%.]+)%s*;") or line:match("^%s*import%s+([%w%.]+)%s*;")
	if import_path then
		local segments = {}
		for seg in import_path:gmatch("[^%.]+") do
			table.insert(segments, seg)
		end
		local pkg_segments = {}
		for _, seg in ipairs(segments) do
			if seg:match("^%u") then
				break
			end
			table.insert(pkg_segments, seg)
		end
		if #pkg_segments > 0 then
			return table.concat(pkg_segments, ".")
		end
	end

	return nil
end

-- ============================================================
-- Project root and path utilities
-- ============================================================

local function find_project_root()
	local markers = { "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts" }
	local path = vim.fn.expand("%:p:h")
	while path ~= "/" do
		for _, marker in ipairs(markers) do
			if vim.fn.filereadable(path .. "/" .. marker) == 1 then
				return path
			end
		end
		path = vim.fn.fnamemodify(path, ":h")
	end
	return nil
end

local function package_to_path(pkg)
	return pkg:gsub("%.", "/")
end

local function find_package_dirs(project_root, pkg)
	local rel = package_to_path(pkg)
	local source_roots = {
		"src/main/java",
		"src/test/java",
		"src/main/kotlin",
		"src/test/kotlin",
	}
	local dirs = {}
	for _, root in ipairs(source_roots) do
		local full = project_root .. "/" .. root .. "/" .. rel
		if vim.fn.isdirectory(full) == 1 then
			table.insert(dirs, { base = project_root .. "/" .. root, dir = full })
		end
	end
	return dirs
end

-- ============================================================
-- File operations
-- ============================================================

local function collect_java_files(dir)
	return vim.fn.globpath(dir, "**/*.java", false, true)
end

local function move_files(old_dir, new_dir)
	vim.fn.mkdir(new_dir, "p")
	local files = vim.fn.globpath(old_dir, "**/*", false, true)
	local direct = vim.fn.globpath(old_dir, "*", false, true)
	local all_files = {}
	local seen = {}
	for _, list in ipairs({ direct, files }) do
		for _, f in ipairs(list) do
			if not seen[f] and vim.fn.isdirectory(f) == 0 then
				seen[f] = true
				table.insert(all_files, f)
			end
		end
	end

	for _, old_path in ipairs(all_files) do
		local relative = old_path:sub(#old_dir + 2)
		local new_path = new_dir .. "/" .. relative
		local new_subdir = vim.fn.fnamemodify(new_path, ":h")
		vim.fn.mkdir(new_subdir, "p")
		vim.fn.rename(old_path, new_path)
	end
end

local function remove_empty_dirs(dir, stop_at)
	local remaining = vim.fn.globpath(dir, "*", false, true)
	if #remaining == 0 then
		vim.fn.delete(dir, "d")
	else
		return
	end
	local parent = vim.fn.fnamemodify(dir, ":h")
	while parent ~= stop_at and #parent > #stop_at do
		local items = vim.fn.globpath(parent, "*", false, true)
		if #items == 0 then
			vim.fn.delete(parent, "d")
			parent = vim.fn.fnamemodify(parent, ":h")
		else
			break
		end
	end
end

local function update_file_contents(filepath, old_pkg, new_pkg)
	local lines = vim.fn.readfile(filepath)
	local changed = false
	local old_escaped = old_pkg:gsub("%.", "%%.")

	for i, line in ipairs(lines) do
		local new_line = line:gsub("(package%s+)" .. old_escaped .. "([%.%w]*%s*;)", "%1" .. new_pkg .. "%2")
		new_line = new_line:gsub("(import%s+)" .. old_escaped .. "(%.[%w%.%*]+%s*;)", "%1" .. new_pkg .. "%2")
		new_line = new_line:gsub("(import%s+static%s+)" .. old_escaped .. "(%.[%w%.%*]+%s*;)", "%1" .. new_pkg .. "%2")
		if new_line ~= line then
			lines[i] = new_line
			changed = true
		end
	end

	if changed then
		vim.fn.writefile(lines, filepath)
	end
	return changed
end

-- ============================================================
-- Buffer management
-- ============================================================

local function reload_affected_buffers(affected_files)
	local affected_set = {}
	for _, f in ipairs(affected_files) do
		affected_set[vim.fn.fnamemodify(f, ":p")] = true
	end

	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			local name = vim.api.nvim_buf_get_name(buf)
			if affected_set[name] then
				vim.api.nvim_buf_call(buf, function()
					vim.cmd("edit!")
				end)
			end
		end
	end
end

local function update_moved_buffers(old_dir, new_dir)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			local name = vim.api.nvim_buf_get_name(buf)
			if name:sub(1, #old_dir) == old_dir then
				local new_name = new_dir .. name:sub(#old_dir + 1)
				vim.api.nvim_buf_set_name(buf, new_name)
				vim.api.nvim_buf_call(buf, function()
					vim.cmd("edit!")
				end)
			end
		end
	end
end

-- ============================================================
-- Path/package conversion utilities
-- ============================================================

local source_roots = {
	"src/main/java",
	"src/test/java",
	"src/main/kotlin",
	"src/test/kotlin",
}

-- ============================================================
-- General file move with language-aware import updating
-- ============================================================

--- Derives the Java package from a directory path relative to a source root.
--- Returns nil if the directory is not under a known source root.
local function dir_to_java_package(project_root, dir)
	for _, root in ipairs(source_roots) do
		local base = project_root .. "/" .. root
		if dir:sub(1, #base) == base then
			local rel = dir:sub(#base + 2)
			if rel == "" then
				return ""
			end
			return rel:gsub("/", ".")
		end
	end
	return nil
end

local function update_java_imports_for_moved_file(project_root, old_pkg, new_pkg, class)
	local old_fqcn_escaped = old_pkg:gsub("%.", "%%.") .. "%." .. class
	local new_fqcn = new_pkg .. "." .. class
	local all_java = collect_java_files(project_root)
	local affected = {}
	for _, jfile in ipairs(all_java) do
		local jlines = vim.fn.readfile(jfile)
		local changed = false
		for j, jline in ipairs(jlines) do
			local updated = jline:gsub("(import%s+)" .. old_fqcn_escaped .. "(%s*;)", "%1" .. new_fqcn .. "%2")
			updated =
				updated:gsub("(import%s+static%s+)" .. old_fqcn_escaped .. "(%.[%w%.]+%s*;)", "%1" .. new_fqcn .. "%2")
			if updated ~= jline then
				jlines[j] = updated
				changed = true
			end
		end
		if changed then
			vim.fn.writefile(jlines, jfile)
			table.insert(affected, jfile)
		end
	end
	return affected
end

local function move_files_to_dir(project_root, filepaths, dest_dir)
	vim.fn.mkdir(dest_dir, "p")
	local moved_count = 0
	local java_moved = false

	for _, filepath in ipairs(filepaths) do
		local filename = vim.fn.fnamemodify(filepath, ":t")
		local new_path = dest_dir .. "/" .. filename

		if filepath == new_path then
			vim.notify("Skipping (already in destination): " .. filename, vim.log.levels.WARN)
			goto continue
		end

		local old_dir = vim.fn.fnamemodify(filepath, ":h")
		vim.fn.rename(filepath, new_path)
		moved_count = moved_count + 1

		-- Java-specific: update package declaration and imports
		if filename:match("%.java$") and project_root then
			java_moved = true
			local old_pkg = dir_to_java_package(project_root, old_dir)
			local new_pkg = dir_to_java_package(project_root, dest_dir)

			if old_pkg and new_pkg and old_pkg ~= new_pkg then
				local class = vim.fn.fnamemodify(filename, ":r")

				-- Update package declaration in the moved file
				local lines = vim.fn.readfile(new_path)
				for i, line in ipairs(lines) do
					local new_line = line:gsub("^(%s*package%s+)[%w%.]+(%s*;)", "%1" .. new_pkg .. "%2")
					if new_line ~= line then
						lines[i] = new_line
						break
					end
				end
				vim.fn.writefile(lines, new_path)

				-- Update imports across the project
				update_java_imports_for_moved_file(project_root, old_pkg, new_pkg, class)
			end
		end

		-- Update buffer for the moved file
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(buf) then
				local name = vim.api.nvim_buf_get_name(buf)
				if name == filepath then
					vim.api.nvim_buf_set_name(buf, new_path)
					vim.api.nvim_buf_call(buf, function()
						vim.cmd("edit!")
					end)
				end
			end
		end

		-- Clean up empty old directory
		if project_root then
			remove_empty_dirs(old_dir, project_root)
		end

		::continue::
	end

	-- Reload any open java buffers that may have had imports rewritten
	if java_moved then
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(buf) then
				local name = vim.api.nvim_buf_get_name(buf)
				if name:match("%.java$") then
					vim.api.nvim_buf_call(buf, function()
						vim.cmd("edit!")
					end)
				end
			end
		end

		vim.schedule(function()
			vim.cmd("LspRestart jdtls")
		end)
	end

	vim.notify(string.format("Moved %d file(s) to %s", moved_count, dest_dir), vim.log.levels.INFO)
end

-- ============================================================
-- Telescope-based file move picker
-- ============================================================

--- Collects all directories in the project for the destination picker.
local function collect_directories(project_root)
	local dirs = {}
	local seen = {}
	local all = vim.fn.globpath(project_root, "**/", false, true)
	for _, d in ipairs(all) do
		-- Skip hidden dirs and build output
		local rel = d:sub(#project_root + 2):gsub("/$", "")
		if
			rel ~= ""
			and not rel:match("^%.")
			and not rel:match("/%.")
			and not rel:match("^target/")
			and not rel:match("^build/")
			and not rel:match("^node_modules/")
			and not seen[rel]
		then
			seen[rel] = true
			table.insert(dirs, rel)
		end
	end
	table.sort(dirs)
	return dirs
end

function M.telescope_move_files()
	local ok, _ = pcall(require, "telescope")
	if not ok then
		vim.notify("Telescope is required for MoveFile", vim.log.levels.ERROR)
		return
	end

	local project_root = find_project_root()
	if not project_root then
		-- Fall back to git root or cwd
		local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
		if vim.v.shell_error == 0 and git_root ~= "" then
			project_root = git_root
		else
			project_root = vim.fn.getcwd()
		end
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	-- Collect all files (not just Java)
	local all_files = vim.fn.globpath(project_root, "**/*", false, true)
	local entries = {}
	for _, f in ipairs(all_files) do
		if
			vim.fn.isdirectory(f) == 0
			and not f:match("/%.git/")
			and not f:match("/target/")
			and not f:match("/build/")
			and not f:match("/node_modules/")
		then
			table.insert(entries, {
				display = f:sub(#project_root + 2),
				path = f,
			})
		end
	end

	pickers
		.new({}, {
			prompt_title = "Select files to move (Tab to select, Enter to confirm)",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return {
						value = entry.path,
						display = entry.display,
						ordinal = entry.display,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local picker = action_state.get_current_picker(prompt_bufnr)
					local selections = picker:get_multi_selection()

					if #selections == 0 then
						local entry = action_state.get_selected_entry()
						if entry then
							selections = { entry }
						end
					end

					actions.close(prompt_bufnr)

					if #selections == 0 then
						return
					end

					local filepaths = {}
					for _, sel in ipairs(selections) do
						table.insert(filepaths, sel.value)
					end

					-- Destination picker: show project directories
					local directories = collect_directories(project_root)

					pickers
						.new({}, {
							prompt_title = "Destination directory (type new or select existing)",
							finder = finders.new_table({
								results = directories,
							}),
							sorter = conf.generic_sorter({}),
							attach_mappings = function(dest_bufnr)
								actions.select_default:replace(function()
									local dest_entry = action_state.get_selected_entry()
									local prompt = action_state.get_current_picker(dest_bufnr):_get_prompt()
									actions.close(dest_bufnr)

									local dest_rel = dest_entry and dest_entry[1] or prompt
									if not dest_rel or dest_rel == "" then
										vim.notify("No destination specified.", vim.log.levels.WARN)
										return
									end

									local dest_dir = project_root .. "/" .. dest_rel
									move_files_to_dir(project_root, filepaths, dest_dir)
								end)
								return true
							end,
						})
						:find()
				end)
				return true
			end,
		})
		:find()
end

-- ============================================================
-- Main rename orchestration
-- ============================================================

function M.rename_package(old_pkg, new_pkg)
	if not new_pkg or new_pkg == "" or new_pkg == old_pkg then
		vim.notify("Package rename cancelled.", vim.log.levels.INFO)
		return
	end

	if not new_pkg:match("^[%l][%w]*%.[%w%.]+$") then
		vim.notify("Invalid package name: " .. new_pkg, vim.log.levels.ERROR)
		return
	end

	local project_root = find_project_root()
	if not project_root then
		vim.notify("Could not find project root (no pom.xml or build.gradle).", vim.log.levels.ERROR)
		return
	end

	-- Phase 1: Find and move package directories
	local pkg_dirs = find_package_dirs(project_root, old_pkg)
	if #pkg_dirs == 0 then
		vim.notify("No directories found for package: " .. old_pkg, vim.log.levels.WARN)
	end

	local new_rel = package_to_path(new_pkg)
	for _, entry in ipairs(pkg_dirs) do
		local new_dir = entry.base .. "/" .. new_rel
		move_files(entry.dir, new_dir)
		update_moved_buffers(entry.dir, new_dir)
		remove_empty_dirs(entry.dir, entry.base)
	end

	-- Phase 2: Update all .java files in the project
	local all_java = collect_java_files(project_root)
	local affected = {}
	for _, filepath in ipairs(all_java) do
		if update_file_contents(filepath, old_pkg, new_pkg) then
			table.insert(affected, filepath)
		end
	end

	-- Phase 3: Reload affected buffers
	reload_affected_buffers(affected)

	-- Phase 4: Notify and restart LSP
	local msg = string.format(
		"Renamed package: %s -> %s\n  Moved %d source root(s), updated %d file(s).",
		old_pkg,
		new_pkg,
		#pkg_dirs,
		#affected
	)
	vim.notify(msg, vim.log.levels.INFO)

	vim.schedule(function()
		vim.cmd("LspRestart jdtls")
	end)
end

function M.smart_rename()
	local pkg = detect_package_on_line()
	if pkg and vim.bo.filetype == "java" then
		vim.ui.input({ prompt = "Rename package: ", default = pkg }, function(new_pkg)
			if new_pkg then
				M.rename_package(pkg, new_pkg)
			end
		end)
	else
		vim.lsp.buf.rename()
	end
end

function M.setup()
	vim.api.nvim_create_user_command("JavaRenamePackage", function(opts)
		if opts.args and opts.args ~= "" then
			local parts = vim.split(opts.args, "%s+")
			if #parts == 2 then
				M.rename_package(parts[1], parts[2])
			else
				vim.notify("Usage: :JavaRenamePackage <old_package> <new_package>", vim.log.levels.ERROR)
			end
		else
			local pkg = detect_package_on_line()
			if pkg then
				vim.ui.input({ prompt = "Rename package: ", default = pkg }, function(new_pkg)
					if new_pkg then
						M.rename_package(pkg, new_pkg)
					end
				end)
			else
				vim.notify("Cursor is not on a package declaration or import.", vim.log.levels.WARN)
			end
		end
	end, {
		nargs = "?",
		complete = function()
			return {}
		end,
		desc = "Rename a Java package (move files + update imports)",
	})

	vim.api.nvim_create_user_command("MoveFile", function()
		M.telescope_move_files()
	end, {
		desc = "Move files to a different directory (updates Java imports if applicable)",
	})

	vim.keymap.set("n", "<leader>rm", function()
		M.telescope_move_files()
	end, { desc = "[R]efactor [M]ove file" })
end

return M
