local M = {}

--- Parses the current line to determine if the cursor is on a
--- package declaration or an import statement's package portion.
--- Returns the package name string if yes, nil if no.
local function detect_package_on_line()
  local line = vim.api.nvim_get_current_line()

  -- Match: package com.demo.user;
  local pkg_decl = line:match('^%s*package%s+([%w%.]+)%s*;')
  if pkg_decl then
    return pkg_decl
  end

  -- Match: import com.demo.user.*;  (wildcard import)
  local wildcard = line:match('^%s*import%s+([%w%.]+)%.%*%s*;')
  if wildcard then
    return wildcard
  end

  -- Match: import com.demo.user.UserDto;
  -- Match: import static com.demo.user.UserDto.someMethod;
  -- Strip uppercase-initial segments (class names / members).
  local import_path = line:match('^%s*import%s+static%s+([%w%.]+)%s*;')
    or line:match('^%s*import%s+([%w%.]+)%s*;')
  if import_path then
    local segments = {}
    for seg in import_path:gmatch('[^%.]+') do
      table.insert(segments, seg)
    end
    local pkg_segments = {}
    for _, seg in ipairs(segments) do
      if seg:match('^%u') then
        break
      end
      table.insert(pkg_segments, seg)
    end
    if #pkg_segments > 0 then
      return table.concat(pkg_segments, '.')
    end
  end

  return nil
end

-- ============================================================
-- Project root and path utilities
-- ============================================================

local function find_project_root()
  local markers = { 'pom.xml', 'build.gradle', 'build.gradle.kts', 'settings.gradle', 'settings.gradle.kts' }
  local path = vim.fn.expand('%:p:h')
  while path ~= '/' do
    for _, marker in ipairs(markers) do
      if vim.fn.filereadable(path .. '/' .. marker) == 1 then
        return path
      end
    end
    path = vim.fn.fnamemodify(path, ':h')
  end
  return nil
end

local function package_to_path(pkg)
  return pkg:gsub('%.', '/')
end

local function find_package_dirs(project_root, pkg)
  local rel = package_to_path(pkg)
  local source_roots = {
    'src/main/java',
    'src/test/java',
    'src/main/kotlin',
    'src/test/kotlin',
  }
  local dirs = {}
  for _, root in ipairs(source_roots) do
    local full = project_root .. '/' .. root .. '/' .. rel
    if vim.fn.isdirectory(full) == 1 then
      table.insert(dirs, { base = project_root .. '/' .. root, dir = full })
    end
  end
  return dirs
end

-- ============================================================
-- File operations
-- ============================================================

local function collect_java_files(dir)
  return vim.fn.globpath(dir, '**/*.java', false, true)
end

local function move_files(old_dir, new_dir)
  vim.fn.mkdir(new_dir, 'p')
  local files = vim.fn.globpath(old_dir, '**/*', false, true)
  local direct = vim.fn.globpath(old_dir, '*', false, true)
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
    local new_path = new_dir .. '/' .. relative
    local new_subdir = vim.fn.fnamemodify(new_path, ':h')
    vim.fn.mkdir(new_subdir, 'p')
    vim.fn.rename(old_path, new_path)
  end
end

local function remove_empty_dirs(dir, stop_at)
  local remaining = vim.fn.globpath(dir, '*', false, true)
  if #remaining == 0 then
    vim.fn.delete(dir, 'd')
  else
    return
  end
  local parent = vim.fn.fnamemodify(dir, ':h')
  while parent ~= stop_at and #parent > #stop_at do
    local items = vim.fn.globpath(parent, '*', false, true)
    if #items == 0 then
      vim.fn.delete(parent, 'd')
      parent = vim.fn.fnamemodify(parent, ':h')
    else
      break
    end
  end
end

local function update_file_contents(filepath, old_pkg, new_pkg)
  local lines = vim.fn.readfile(filepath)
  local changed = false
  local old_escaped = old_pkg:gsub('%.', '%%.')

  for i, line in ipairs(lines) do
    local new_line = line:gsub(
      '(package%s+)' .. old_escaped .. '([%.%w]*%s*;)',
      '%1' .. new_pkg .. '%2'
    )
    new_line = new_line:gsub(
      '(import%s+)' .. old_escaped .. '(%.[%w%.%*]+%s*;)',
      '%1' .. new_pkg .. '%2'
    )
    new_line = new_line:gsub(
      '(import%s+static%s+)' .. old_escaped .. '(%.[%w%.%*]+%s*;)',
      '%1' .. new_pkg .. '%2'
    )
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
    affected_set[vim.fn.fnamemodify(f, ':p')] = true
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if affected_set[name] then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd('edit!')
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
          vim.cmd('edit!')
        end)
      end
    end
  end
end

-- ============================================================
-- Main rename orchestration
-- ============================================================

function M.rename_package(old_pkg, new_pkg)
  if not new_pkg or new_pkg == '' or new_pkg == old_pkg then
    vim.notify('Package rename cancelled.', vim.log.levels.INFO)
    return
  end

  if not new_pkg:match('^[%l][%w]*%.[%w%.]+$') then
    vim.notify('Invalid package name: ' .. new_pkg, vim.log.levels.ERROR)
    return
  end

  local project_root = find_project_root()
  if not project_root then
    vim.notify('Could not find project root (no pom.xml or build.gradle).', vim.log.levels.ERROR)
    return
  end

  -- Phase 1: Find and move package directories
  local pkg_dirs = find_package_dirs(project_root, old_pkg)
  if #pkg_dirs == 0 then
    vim.notify('No directories found for package: ' .. old_pkg, vim.log.levels.WARN)
  end

  local new_rel = package_to_path(new_pkg)
  for _, entry in ipairs(pkg_dirs) do
    local new_dir = entry.base .. '/' .. new_rel
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
    'Renamed package: %s -> %s\n  Moved %d source root(s), updated %d file(s).',
    old_pkg, new_pkg, #pkg_dirs, #affected
  )
  vim.notify(msg, vim.log.levels.INFO)

  vim.schedule(function()
    vim.cmd('LspRestart jdtls')
  end)
end

function M.smart_rename()
  local pkg = detect_package_on_line()
  if pkg and vim.bo.filetype == 'java' then
    vim.ui.input(
      { prompt = 'Rename package: ', default = pkg },
      function(new_pkg)
        if new_pkg then
          M.rename_package(pkg, new_pkg)
        end
      end
    )
  else
    vim.lsp.buf.rename()
  end
end

function M.setup()
  vim.api.nvim_create_user_command('JavaRenamePackage', function(opts)
    if opts.args and opts.args ~= '' then
      local parts = vim.split(opts.args, '%s+')
      if #parts == 2 then
        M.rename_package(parts[1], parts[2])
      else
        vim.notify('Usage: :JavaRenamePackage <old_package> <new_package>', vim.log.levels.ERROR)
      end
    else
      local pkg = detect_package_on_line()
      if pkg then
        vim.ui.input(
          { prompt = 'Rename package: ', default = pkg },
          function(new_pkg)
            if new_pkg then
              M.rename_package(pkg, new_pkg)
            end
          end
        )
      else
        vim.notify('Cursor is not on a package declaration or import.', vim.log.levels.WARN)
      end
    end
  end, {
    nargs = '?',
    complete = function() return {} end,
    desc = 'Rename a Java package (move files + update imports)',
  })
end

return M
