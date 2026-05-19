local M = {}

local uv = vim.uv or vim.loop

local state = {
  server = nil,
  timer = nil,
  augroup = nil,
  opts = {},
  instance_id = nil,
  state_dir = nil,
  instances_dir = nil,
  socket_path = nil,
  registry_path = nil,
}

local defaults = {
  include_visible_text = true,
  include_terminal_buffers = false,
  max_lines_per_window = 200,
  max_bytes_per_window = 20000,
  heartbeat_ms = 5000,
  debounce_ms = 150,
}

function M.setup(opts)
  M.start(opts)
end

function M.start(opts)
  state.opts = vim.tbl_deep_extend("force", defaults, opts or {})
  state.state_dir = state.opts.state_dir
    or vim.env.NVIM_CONTEXT_MCP_STATE_DIR
    or vim.env.NVIM_READ_MCP_STATE_DIR
    or (vim.fn.stdpath("state") .. "/nvim-context-mcp")
  state.instances_dir = state.state_dir .. "/instances"
  state.instance_id = vim.fn.hostname() .. ":" .. tostring(vim.fn.getpid())
  state.socket_path = state.instances_dir .. "/" .. tostring(vim.fn.getpid()) .. ".sock"
  state.registry_path = state.instances_dir .. "/" .. tostring(vim.fn.getpid()) .. ".json"

  vim.fn.mkdir(state.instances_dir, "p")
  pcall(vim.fn.delete, state.socket_path)

  local server = uv.new_pipe(false)
  assert(server:bind(state.socket_path))
  server:listen(64, function(err)
    if err then
      vim.schedule(function()
        vim.notify("nvim-context-mcp listen failed: " .. tostring(err), vim.log.levels.WARN)
      end)
      return
    end

    local client = uv.new_pipe(false)
    server:accept(client)
    handle_client(client)
  end)
  state.server = server

  state.augroup = vim.api.nvim_create_augroup("nvim-context-mcp", { clear = true })
  vim.api.nvim_create_autocmd({
    "BufEnter",
    "BufWinEnter",
    "BufWinLeave",
    "CursorMoved",
    "CursorMovedI",
    "DirChanged",
    "TabEnter",
    "TextChanged",
    "TextChangedI",
    "VimResized",
    "WinEnter",
  }, {
    group = state.augroup,
    callback = M.touch,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = state.augroup,
    callback = M.stop,
  })

  state.timer = uv.new_timer()
  state.timer:start(0, state.opts.heartbeat_ms, function()
    vim.schedule(M.write_registry)
  end)
  M.write_registry()
end

function M.stop()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  if state.server then
    state.server:close()
    state.server = nil
  end
  if state.registry_path then
    pcall(vim.fn.delete, state.registry_path)
  end
  if state.socket_path then
    pcall(vim.fn.delete, state.socket_path)
  end
end

do
  local pending = false
  function M.touch()
    if pending then
      return
    end
    pending = true
    vim.defer_fn(function()
      pending = false
      M.write_registry()
    end, state.opts.debounce_ms or defaults.debounce_ms)
  end
end

function M.write_registry()
  if not state.registry_path then
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local active_path = vim.api.nvim_buf_get_name(current_buf)
  if active_path == "" then
    active_path = nil
  end

  local record = {
    schemaVersion = 1,
    source = "nvim-context-mcp",
    instanceId = state.instance_id,
    pid = vim.fn.getpid(),
    host = vim.fn.hostname(),
    cwd = vim.fn.getcwd(),
    socketPath = state.socket_path,
    updatedAt = os.time(),
    activePath = active_path,
  }

  vim.fn.writefile({ vim.json.encode(record) }, state.registry_path)
end

function M.visible_context()
  local current_tab = vim.api.nvim_get_current_tabpage()
  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(current_win)

  local tabs = {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local windows = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_is_valid(win) then
        table.insert(windows, window_context(win, win == current_win))
      end
    end
    table.insert(tabs, {
      tabnr = vim.api.nvim_tabpage_get_number(tab),
      current = tab == current_tab,
      windows = windows,
    })
  end

  return {
    schemaVersion = 1,
    source = "nvim-context-mcp",
    instanceId = state.instance_id,
    pid = vim.fn.getpid(),
    host = vim.fn.hostname(),
    cwd = vim.fn.getcwd(),
    updatedAt = os.time(),
    active = {
      tabnr = vim.api.nvim_tabpage_get_number(current_tab),
      winid = current_win,
      bufnr = current_buf,
      path = vim.api.nvim_buf_get_name(current_buf),
      cursor = { line = cursor[1], column = cursor[2] },
    },
    tabs = tabs,
  }
end

function M.handle_request(request)
  if request.method == "ping" then
    return { ok = true }
  elseif request.method == "visible_context" then
    return M.visible_context()
  end

  error("unknown method: " .. tostring(request.method))
end

function handle_client(client)
  local buffer = ""
  client:read_start(function(err, chunk)
    if err then
      client:close()
      return
    end
    if not chunk then
      return
    end

    buffer = buffer .. chunk
    local newline = buffer:find("\n", 1, true)
    if not newline then
      return
    end

    local line = buffer:sub(1, newline - 1)
    client:read_stop()
    vim.schedule(function()
      local response = handle_line(line)
      client:write(vim.json.encode(response) .. "\n", function()
        client:close()
      end)
    end)
  end)
end

function handle_line(line)
  local ok, request = pcall(vim.json.decode, line)
  if not ok then
    return rpc_error(nil, -32700, "Parse error")
  end

  local success, result = pcall(M.handle_request, request)
  if not success then
    return rpc_error(request.id, -32603, tostring(result))
  end

  return {
    jsonrpc = "2.0",
    id = request.id,
    result = result,
  }
end

function rpc_error(id, code, message)
  return {
    jsonrpc = "2.0",
    id = id,
    error = {
      code = code,
      message = message,
    },
  }
end

function window_context(win, current)
  local buf = vim.api.nvim_win_get_buf(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local start_line = vim.fn.line("w0", win)
  local end_line = vim.fn.line("w$", win)
  local path = vim.api.nvim_buf_get_name(buf)
  local buftype = vim.bo[buf].buftype

  local context = {
    winid = win,
    current = current,
    buffer = {
      bufnr = buf,
      path = path,
      name = path ~= "" and vim.fn.fnamemodify(path, ":t") or "[No Name]",
      filetype = vim.bo[buf].filetype,
      buftype = buftype,
      modified = vim.bo[buf].modified,
      listed = vim.bo[buf].buflisted,
    },
    cursor = { line = cursor[1], column = cursor[2] },
    visibleRange = { start = start_line, ["end"] = end_line },
  }

  if state.opts.include_visible_text
    and (buftype ~= "terminal" or state.opts.include_terminal_buffers)
  then
    context.visibleText = visible_lines(buf, start_line, end_line)
  end

  return context
end

function visible_lines(buf, start_line, end_line)
  local line_count = math.max(0, end_line - start_line + 1)
  local max_lines = math.min(line_count, state.opts.max_lines_per_window)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, start_line - 1 + max_lines, false)
  local max_bytes = state.opts.max_bytes_per_window
  local used = 0
  local out = {}

  for _, line in ipairs(lines) do
    used = used + #line + 1
    if used > max_bytes then
      table.insert(out, "[truncated]")
      break
    end
    table.insert(out, line)
  end

  return out
end

return M
