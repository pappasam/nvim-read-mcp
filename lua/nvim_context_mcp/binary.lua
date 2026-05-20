local M = {}

local uv = vim.uv or vim.loop

local state = {
  opts = {},
  installing = false,
  status = nil,
  commands_created = false,
}

local defaults = {
  auto_install = true,
  expose_on_path = true,
  bin_dir = vim.fn.expand("~/.local/bin"),
  force_version = nil,
  force_target = nil,
  extra_curl_args = {},
}

local binary_paths
local checksum_command
local checksum_from_output
local download_file
local download_managed_binary
local expose_binary_on_path
local extract_archive
local install_extracted_binary
local managed_binary_current
local path_contains
local path_note
local plugin_release_tag
local plugin_root
local system_target
local verify_archive_checksum

function M.setup(opts)
  state.opts = vim.tbl_deep_extend("force", defaults, opts or {})
end

function M.create_commands()
  if state.commands_created then
    return
  end
  state.commands_created = true

  local subcommands = {
    status = M.status_command,
    install = function()
      M.ensure({ force = true, quiet = false })
    end,
  }

  vim.api.nvim_create_user_command("NvimContextMcp", function(cmd)
    local subcommand = cmd.fargs[1] or "status"
    local handler = subcommands[subcommand]
    if not handler then
      vim.notify("nvim-context-mcp: unknown subcommand: " .. subcommand, vim.log.levels.ERROR)
      return
    end
    handler()
  end, {
    nargs = "?",
    complete = function()
      return vim.tbl_keys(subcommands)
    end,
    desc = "nvim-context-mcp",
  })
end

function M.ensure(opts)
  opts = opts or {}
  if not state.opts.auto_install and not opts.force then
    return
  end
  if state.installing then
    return
  end

  local paths = binary_paths(state.opts)
  local version = state.opts.force_version or plugin_release_tag()
  if not version then
    state.status = {
      ok = false,
      reason = "not on a release tag; skipping managed binary install",
      binary = paths.binary,
    }
    return
  end

  local target = state.opts.force_target or system_target()
  if not target then
    state.status = {
      ok = false,
      reason = "unsupported platform for managed binary install",
      binary = paths.binary,
      version = version,
    }
    if not opts.quiet then
      vim.notify("nvim-context-mcp: unsupported platform for managed binary install", vim.log.levels.WARN)
    end
    return
  end

  if not opts.force and managed_binary_current(paths, version) then
    local ok, reason = expose_binary_on_path(paths, state.opts)
    state.status = {
      ok = ok,
      reason = reason,
      binary = paths.binary,
      link = paths.link,
      version = version,
      target = target,
    }
    return
  end

  state.installing = true
  state.status = {
    ok = false,
    reason = "installing",
    binary = paths.binary,
    link = paths.link,
    version = version,
    target = target,
  }
  if not opts.quiet then
    vim.notify("nvim-context-mcp: downloading " .. version .. " for " .. target, vim.log.levels.INFO)
  end

  download_managed_binary(version, target, paths, state.opts, function(ok, err)
    state.installing = false
    if not ok then
      state.status = {
        ok = false,
        reason = err,
        binary = paths.binary,
        link = paths.link,
        version = version,
        target = target,
      }
      vim.notify("nvim-context-mcp: binary install failed: " .. tostring(err), vim.log.levels.WARN)
      return
    end

    local exposed, expose_reason = expose_binary_on_path(paths, state.opts)
    state.status = {
      ok = exposed,
      reason = expose_reason,
      binary = paths.binary,
      link = paths.link,
      version = version,
      target = target,
    }
    if not opts.quiet then
      vim.notify("nvim-context-mcp: binary installed at " .. paths.binary, vim.log.levels.INFO)
    end
    if not exposed and expose_reason then
      vim.notify("nvim-context-mcp: " .. expose_reason, vim.log.levels.WARN)
    end
  end)
end

function M.status()
  local paths = binary_paths(state.opts)
  local version = state.opts.force_version or plugin_release_tag()
  local target = state.opts.force_target or system_target()
  local current = version and managed_binary_current(paths, version) or false
  return vim.tbl_extend("force", state.status or {}, {
    binary = paths.binary,
    link = paths.link,
    link_dir = vim.fn.fnamemodify(paths.link, ":h"),
    version = version,
    target = target,
    installed = vim.fn.executable(paths.binary) == 1,
    current = current,
    path_executable = vim.fn.executable("nvim-context-mcp") == 1,
  })
end

function M.status_command()
  local status = M.status()
  local lines = {
    "nvim-context-mcp binary status:",
    "  binary: " .. tostring(status.binary),
    "  installed: " .. tostring(status.installed),
    "  current: " .. tostring(status.current),
    "  version: " .. tostring(status.version or "unknown"),
    "  target: " .. tostring(status.target or "unsupported"),
    "  on PATH: " .. tostring(status.path_executable),
  }
  if status.link then
    table.insert(lines, "  link: " .. tostring(status.link))
  end
  if status.link_dir then
    table.insert(lines, "  link dir: " .. tostring(status.link_dir))
  end
  if status.reason then
    table.insert(lines, "  note: " .. tostring(status.reason))
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

function plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

function plugin_release_tag()
  local root = plugin_root()
  if vim.fn.isdirectory(root .. "/.git") ~= 1 then
    return nil
  end

  local result = vim.system({
    "git",
    "--git-dir",
    root .. "/.git",
    "--work-tree",
    root,
    "describe",
    "--tags",
    "--exact-match",
  }, { text = true }):wait()
  if result.code ~= 0 then
    return nil
  end

  local tag = (result.stdout or ""):match("^%s*(.-)%s*$")
  if tag == "" then
    return nil
  end
  return tag
end

function system_target()
  local uname = uv.os_uname()
  local sysname = (uname.sysname or ""):lower()
  local machine = (uname.machine or ""):lower()

  local arch
  if machine == "x86_64" or machine == "amd64" then
    arch = "x86_64"
  elseif machine == "arm64" or machine == "aarch64" then
    arch = "aarch64"
  else
    return nil
  end

  if sysname:find("linux", 1, true) then
    return arch .. "-unknown-linux-gnu"
  elseif sysname:find("darwin", 1, true) and arch == "aarch64" then
    return arch .. "-apple-darwin"
  end

  return nil
end

function binary_paths(opts)
  local data_dir = vim.fn.stdpath("data") .. "/nvim-context-mcp"
  local exe = vim.fn.has("win32") == 1 and "nvim-context-mcp.exe" or "nvim-context-mcp"
  local bin_dir = vim.fn.expand(opts.bin_dir or defaults.bin_dir)
  return {
    root = data_dir,
    bin_dir = data_dir .. "/bin",
    binary = data_dir .. "/bin/" .. exe,
    version = data_dir .. "/version",
    work = data_dir .. "/download",
    link = bin_dir .. "/" .. exe,
  }
end

function managed_binary_current(paths, version)
  if vim.fn.executable(paths.binary) ~= 1 then
    return false
  end
  local ok, lines = pcall(vim.fn.readfile, paths.version)
  if not ok or not lines[1] then
    return false
  end
  return lines[1] == version
end

function download_managed_binary(version, target, paths, opts, callback)
  vim.fn.mkdir(paths.work, "p", 448)
  local archive_name = "nvim-context-mcp-" .. version .. "-" .. target .. ".tar.gz"
  local archive_path = paths.work .. "/" .. archive_name
  local sums_path = paths.work .. "/SHA256SUMS"
  local base_url = "https://github.com/pappasam/nvim-context-mcp/releases/download/" .. version .. "/"

  download_file(base_url .. archive_name, archive_path, opts, function(archive_ok, archive_err)
    if not archive_ok then
      callback(false, archive_err)
      return
    end

    download_file(base_url .. "SHA256SUMS", sums_path, opts, function(sums_ok, sums_err)
      if not sums_ok then
        callback(false, sums_err)
        return
      end

      verify_archive_checksum(archive_path, archive_name, sums_path, function(checksum_ok, checksum_err)
        if not checksum_ok then
          callback(false, checksum_err)
          return
        end

        extract_archive(archive_path, paths.work, archive_name:gsub("%.tar%.gz$", ""), function(extract_ok, extract_err)
          if not extract_ok then
            callback(false, extract_err)
            return
          end

          local extracted_binary = paths.work .. "/" .. archive_name:gsub("%.tar%.gz$", "") .. "/nvim-context-mcp"
          install_extracted_binary(extracted_binary, paths, version, callback)
        end)
      end)
    end)
  end)
end

function download_file(url, output_path, opts, callback)
  local args = {
    "curl",
    "--fail",
    "--location",
    "--silent",
    "--show-error",
    "--create-dirs",
    "--output",
    output_path,
  }
  vim.list_extend(args, opts.extra_curl_args or {})
  table.insert(args, url)

  vim.system(args, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(false, "failed to download " .. url .. ": " .. tostring(result.stderr))
        return
      end
      callback(true)
    end)
  end)
end

function verify_archive_checksum(archive_path, archive_name, sums_path, callback)
  local expected = nil
  local ok, lines = pcall(vim.fn.readfile, sums_path)
  if ok then
    for _, line in ipairs(lines) do
      local hash, file = line:match("^(%x+)%s+%*?(.+)$")
      if file == archive_name then
        expected = hash
        break
      end
    end
  end

  if not expected then
    callback(false, "checksum for " .. archive_name .. " not found in SHA256SUMS")
    return
  end

  local command = checksum_command(archive_path)
  if not command then
    callback(false, "no supported SHA256 command found")
    return
  end

  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(false, "failed to calculate checksum: " .. tostring(result.stderr))
        return
      end

      local actual = checksum_from_output(result.stdout or "")
      if actual ~= expected then
        callback(false, "checksum mismatch for " .. archive_name)
        return
      end
      callback(true)
    end)
  end)
end

function checksum_command(path)
  if vim.fn.executable("sha256sum") == 1 then
    return { "sha256sum", path }
  end
  if vim.fn.executable("shasum") == 1 then
    return { "shasum", "-a", "256", path }
  end
  return nil
end

function checksum_from_output(output)
  return output:match("(%x+)")
end

function extract_archive(archive_path, work_dir, extracted_dir, callback)
  local target_dir = work_dir .. "/" .. extracted_dir
  pcall(vim.fn.delete, target_dir, "rf")
  vim.system({ "tar", "-xzf", archive_path, "-C", work_dir }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(false, "failed to extract archive: " .. tostring(result.stderr))
        return
      end
      callback(true)
    end)
  end)
end

function install_extracted_binary(extracted_binary, paths, version, callback)
  if vim.fn.filereadable(extracted_binary) ~= 1 then
    callback(false, "archive did not contain nvim-context-mcp")
    return
  end

  vim.fn.mkdir(paths.bin_dir, "p", 448)
  local tmp_binary = paths.binary .. ".tmp"
  pcall(vim.fn.delete, tmp_binary)
  local ok, err = pcall(uv.fs_copyfile, extracted_binary, tmp_binary)
  if not ok then
    callback(false, "failed to copy binary: " .. tostring(err))
    return
  end
  pcall(vim.fn.setfperm, tmp_binary, "rwxr-xr-x")

  ok, err = pcall(uv.fs_rename, tmp_binary, paths.binary)
  if not ok then
    callback(false, "failed to install binary: " .. tostring(err))
    return
  end
  pcall(vim.fn.writefile, { version }, paths.version)
  callback(true)
end

function expose_binary_on_path(paths, opts)
  if not opts.expose_on_path then
    return true, "PATH exposure disabled"
  end

  local existing = vim.fn.exepath("nvim-context-mcp")
  if existing ~= "" and vim.fn.resolve(existing) ~= vim.fn.resolve(paths.link) then
    return true, "nvim-context-mcp already exists on PATH at " .. existing
  end

  local link_dir = vim.fn.fnamemodify(paths.link, ":h")
  vim.fn.mkdir(link_dir, "p", 493)
  if vim.fn.filereadable(paths.link) == 1 or vim.fn.executable(paths.link) == 1 then
    if vim.fn.resolve(paths.link) == vim.fn.resolve(paths.binary) then
      return path_contains(link_dir), path_note(link_dir)
    end
    return false, paths.link .. " already exists and is not managed by nvim-context-mcp"
  end

  local ok, err = pcall(uv.fs_symlink, paths.binary, paths.link)
  if not ok then
    return false, "failed to create PATH symlink at " .. paths.link .. ": " .. tostring(err)
  end

  return path_contains(link_dir), path_note(link_dir)
end

function path_contains(dir)
  local separator = vim.fn.has("win32") == 1 and ";" or ":"
  local path = vim.env.PATH or ""
  for entry in string.gmatch(path, "([^" .. separator .. "]+)") do
    if vim.fn.fnamemodify(entry, ":p") == vim.fn.fnamemodify(dir, ":p") then
      return true
    end
  end
  return false
end

function path_note(dir)
  if path_contains(dir) then
    return "binary is available on PATH"
  end
  return dir .. " is not on PATH; Codex and Claude Code may not find nvim-context-mcp"
end

return M
