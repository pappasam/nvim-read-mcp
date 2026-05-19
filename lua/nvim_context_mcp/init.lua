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
  max_lines_per_buffer = 1000,
  max_bytes_per_buffer = 100000,
  max_diagnostics = 1000,
  heartbeat_ms = 5000,
  debounce_ms = 150,
}

function M.setup(opts)
  M.start(opts)
end

function M.start(opts)
  state.opts = vim.tbl_deep_extend("force", defaults, opts or {})
  if state.server then
    M.write_registry()
    return
  end

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

function M.buffers()
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      table.insert(buffers, buffer_summary(buf))
    end
  end

  table.sort(buffers, function(left, right)
    if left.listed ~= right.listed then
      return left.listed
    end
    if left.loaded ~= right.loaded then
      return left.loaded
    end
    return left.bufnr < right.bufnr
  end)

  return {
    schemaVersion = 1,
    source = "nvim-context-mcp",
    instanceId = state.instance_id,
    pid = vim.fn.getpid(),
    host = vim.fn.hostname(),
    cwd = vim.fn.getcwd(),
    updatedAt = os.time(),
    buffers = buffers,
  }
end

function M.buffer_text(params)
  params = params or {}
  local buf = resolve_buffer(params)
  ensure_loaded_buffer(buf)

  local line_count = vim.api.nvim_buf_line_count(buf)
  local start_line = clamp_line(params.startLine or 1, line_count + 1)
  local end_line = clamp_line(params.endLine or line_count, line_count)
  if end_line < start_line then
    end_line = start_line - 1
  end

  local max_lines = params.maxLines or state.opts.max_lines_per_buffer
  local max_bytes = params.maxBytes or state.opts.max_bytes_per_buffer
  local lines, truncated = lines_from_buffer(buf, start_line, end_line, max_lines, max_bytes)

  return {
    schemaVersion = 1,
    source = "nvim-context-mcp",
    instanceId = state.instance_id,
    buffer = buffer_summary(buf),
    range = { start = start_line, ["end"] = end_line },
    text = lines,
    truncated = truncated,
  }
end

function M.diagnostics(params)
  params = params or {}
  local buffers = {}
  if params.bufnr or params.path then
    buffers = { resolve_buffer(params) }
  else
    buffers = vim.api.nvim_list_bufs()
  end

  local result = {}
  local max_diagnostics = positive_integer(params.maxDiagnostics, state.opts.max_diagnostics)
  local remaining = max_diagnostics
  local truncated = false
  local severity_filter = normalize_severity(params.severity)
  for _, buf in ipairs(buffers) do
    if remaining <= 0 then
      truncated = true
      break
    end
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      local diagnostics = {}
      for _, diagnostic in ipairs(vim.diagnostic.get(buf)) do
        if not severity_filter or diagnostic.severity == severity_filter then
          if remaining <= 0 then
            truncated = true
            break
          end
          table.insert(diagnostics, diagnostic_summary(diagnostic))
          remaining = remaining - 1
        end
      end
      table.insert(result, {
        buffer = buffer_summary(buf),
        diagnostics = diagnostics,
      })
    end
  end

  return {
    schemaVersion = 1,
    source = "nvim-context-mcp",
    instanceId = state.instance_id,
    pid = vim.fn.getpid(),
    host = vim.fn.hostname(),
    cwd = vim.fn.getcwd(),
    updatedAt = os.time(),
    buffers = result,
    truncated = truncated,
    maxDiagnostics = max_diagnostics,
  }
end

function M.handle_request(request)
  if request.method == "ping" then
    return { ok = true }
  elseif request.method == "visible_context" then
    return M.visible_context()
  elseif request.method == "buffers" then
    return M.buffers()
  elseif request.method == "buffer_text" then
    return M.buffer_text(request.params)
  elseif request.method == "diagnostics" then
    return M.diagnostics(request.params)
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
      client:close()
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
  local lines = lines_from_buffer(
    buf,
    start_line,
    end_line,
    state.opts.max_lines_per_window,
    state.opts.max_bytes_per_window
  )

  return lines
end

function lines_from_buffer(buf, start_line, end_line, max_lines, max_bytes)
  max_lines = positive_integer(max_lines, state.opts.max_lines_per_buffer)
  max_bytes = positive_integer(max_bytes, state.opts.max_bytes_per_buffer)

  local line_count = math.max(0, end_line - start_line + 1)
  local limited_lines = math.min(line_count, max_lines)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, start_line - 1 + limited_lines, false)
  local used = 0
  local out = {}
  local truncated = limited_lines < line_count

  for _, line in ipairs(lines) do
    used = used + #line + 1
    if used > max_bytes then
      truncated = true
      break
    end
    table.insert(out, line)
  end

  return out, truncated
end

function buffer_summary(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  local loaded = vim.api.nvim_buf_is_loaded(buf)
  local line_count = loaded and vim.api.nvim_buf_line_count(buf) or 0
  return {
    bufnr = buf,
    path = path,
    name = path ~= "" and vim.fn.fnamemodify(path, ":t") or "[No Name]",
    filetype = loaded and vim.bo[buf].filetype or "",
    buftype = loaded and vim.bo[buf].buftype or "",
    modified = loaded and vim.bo[buf].modified or false,
    listed = vim.bo[buf].buflisted,
    loaded = loaded,
    lineCount = line_count,
  }
end

function resolve_buffer(params)
  if params.bufnr then
    local bufnr = tonumber(params.bufnr)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      return bufnr
    end
    error("invalid buffer number: " .. tostring(params.bufnr))
  end

  if params.path then
    local target = vim.fn.fnamemodify(params.path, ":p")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local path = vim.api.nvim_buf_get_name(buf)
      if path ~= "" and vim.fn.fnamemodify(path, ":p") == target then
        return buf
      end
    end
    error("buffer not found for path: " .. tostring(params.path))
  end

  return vim.api.nvim_get_current_buf()
end

function ensure_loaded_buffer(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then
    error("buffer is not loaded: " .. tostring(buf))
  end
end

function clamp_line(value, max_line)
  local line = tonumber(value) or 1
  line = math.floor(line)
  if line < 1 then
    return 1
  end
  if line > max_line then
    return max_line
  end
  return line
end

function positive_integer(value, fallback)
  local number = tonumber(value)
  if not number or number < 1 then
    number = tonumber(fallback) or 1
  end

  number = math.floor(number)
  if number < 1 then
    return 1
  end
  return number
end

function normalize_severity(value)
  if value == nil or value == "" then
    return nil
  end
  if type(value) == "number" then
    return value
  end

  local normalized = tostring(value):upper()
  if normalized == "ERROR" then
    return vim.diagnostic.severity.ERROR
  elseif normalized == "WARN" or normalized == "WARNING" then
    return vim.diagnostic.severity.WARN
  elseif normalized == "INFO" then
    return vim.diagnostic.severity.INFO
  elseif normalized == "HINT" then
    return vim.diagnostic.severity.HINT
  end

  error("invalid diagnostic severity: " .. tostring(value))
end

function diagnostic_summary(diagnostic)
  local namespace = vim.diagnostic.get_namespace(diagnostic.namespace)
  return {
    line = diagnostic.lnum + 1,
    column = diagnostic.col,
    endLine = diagnostic.end_lnum and (diagnostic.end_lnum + 1) or nil,
    endColumn = diagnostic.end_col,
    severity = severity_name(diagnostic.severity),
    message = diagnostic.message,
    source = diagnostic.source,
    code = diagnostic.code,
    namespace = namespace and namespace.name or tostring(diagnostic.namespace),
  }
end

function severity_name(severity)
  if severity == vim.diagnostic.severity.ERROR then
    return "ERROR"
  elseif severity == vim.diagnostic.severity.WARN then
    return "WARN"
  elseif severity == vim.diagnostic.severity.INFO then
    return "INFO"
  elseif severity == vim.diagnostic.severity.HINT then
    return "HINT"
  end

  return tostring(severity)
end

return M
