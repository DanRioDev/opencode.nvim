-- Gathers editor context

local util = require('opencode.util')
local config = require('opencode.config').get()
local state = require('opencode.state')
local context_cache = require('opencode.context_cache')

local M = {}

local cache = { timestamp = 0, last_changedtick = 0, data = nil }

local cwd = vim.fn.getcwd()

local function is_in_cwd(path)
  if not path or path == '' then
    return false
  end
  return vim.startswith(vim.fn.fnamemodify(path, ':p'), cwd)
end

-- Privacy filter: redact paths outside project root
local function filter_path_privacy(path)
  if not path or path == '' then
    return path
  end

  -- Check if privacy filtering is enabled in config
  if config.context and config.context.privacy_filter and config.context.privacy_filter.enabled == false then
    return path
  end

  -- If path is within project, return as-is
  if is_in_cwd(path) then
    return path
  end

  -- Redact paths outside project root
  local basename = vim.fn.fnamemodify(path, ':t')
  return '[EXTERNAL]/' .. basename
end

-- Secret detection: check if content contains likely secrets
local function contains_secret(content)
  if not content or content == '' then
    return false
  end

  -- Check if secret filtering is enabled in config
  if config.context and config.context.secret_filter and config.context.secret_filter.enabled == false then
    return false
  end

  -- Common secret patterns
  local secret_patterns = {
    -- API keys and tokens (long alphanumeric strings)
    '[%w%-_]+%.[%w%-_]+%.[%w%-_]+', -- JWT tokens (xxx.yyy.zzz)
    'api[_%- ]?key[_%- ]?[:=][%s]*[\'"]?[%w%-_]+[\'"]?', -- API key assignments
    'token[_%- ]?[:=][%s]*[\'"]?[%w%-_]+[\'"]?', -- Token assignments
    'password[_%- ]?[:=][%s]*[\'"]?[%w%-_]+[\'"]?', -- Password assignments
    'secret[_%- ]?[:=][%s]*[\'"]?[%w%-_]+[\'"]?', -- Secret assignments
    -- Long hex strings (potential keys)
    '[0-9a-fA-F]{32,}',
    -- AWS-style keys
    'AKIA[0-9A-Z]{16}',
    -- Private keys
    '%-%-%-%-%-BEGIN [%w%s]+ PRIVATE KEY%-%-%-%-%-',
  }

  for _, pattern in ipairs(secret_patterns) do
    if content:match(pattern) then
      return true
    end
  end

  return false
end

-- Helper function to get surrounding lines for a specific buffer and line
---@param bufnr number
---@param line_num number
---@return table|nil
local function get_surrounding_lines(bufnr, line_num)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local lines_above = config.context.cursor_surrounding.lines_above or 3
  local lines_below = config.context.cursor_surrounding.lines_below or 3

  local start_line = math.max(1, line_num - lines_above)
  local end_line = math.min(vim.api.nvim_buf_line_count(bufnr), line_num + lines_below)

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, start_line - 1, end_line, false)
  if not ok then
    return nil
  end

  return {
    lines = lines,
    start_line = start_line,
    end_line = end_line,
    current_line = line_num,
  }
end

M.context = {
  -- current file
  current_file = nil,
  cursor_data = nil,

  -- attachments
  mentioned_files = nil,
  mentioned_files_content = nil,
  selections = nil,
  linter_errors = nil,
  mentioned_subagents = nil,
  vectorcode_snippets = nil,

  -- new context types
  marks = nil,
  jumplist = nil,
  recent_buffers = nil,
  undo_history = nil,
  windows_tabs = nil,
  highlights = nil,
  session_info = nil,
  registers = nil,
  command_history = nil,
  search_history = nil,
  debug_data = nil,
  lsp_context = nil,
  plugin_versions = nil,
  git_info = nil,
  fold_info = nil,
  cursor_surrounding = nil,
  quickfix_loclist = nil,
  macros = nil,
  terminal_buffers = nil,
  session_duration = nil,
}

-- Track session start time for duration calculation
M.session_start_time = vim.loop.hrtime()

-- Helper function to get cache TTL from config
local function get_cache_ttl(key, default)
  local cfg = require('opencode.config').get()
  if cfg.context and cfg.context.cache_ttl and cfg.context.cache_ttl[key] then
    return cfg.context.cache_ttl[key]
  end
  -- Longer defaults for expensive operations to reduce recomputation
  local heavy_ttls = {
    git_info = 10000, -- 10 seconds
    lsp_context = 5000, -- 5 seconds
    plugin_versions = 60000, -- 1 minute
    vectorcode_snippets = 30000, -- 30 seconds
    recent_buffers = 5000, -- 5 seconds
    highlights = 5000, -- 5 seconds
  }
  return heavy_ttls[key] or default or context_cache.DEFAULT_TTL
end

function M.unload_attachments()
  M.context.mentioned_files = nil
  M.context.mentioned_files_content = nil
  M.context.selections = nil
  M.context.linter_errors = nil
  M.context.marks = nil
  M.context.jumplist = nil
  M.context.recent_buffers = nil
  M.context.undo_history = nil
  M.context.windows_tabs = nil
  M.context.highlights = nil
  M.context.session_info = nil
  M.context.registers = nil
  M.context.command_history = nil
  M.context.search_history = nil
  M.context.debug_data = nil
  M.context.lsp_context = nil
  M.context.plugin_versions = nil
  M.context.git_info = nil
  M.context.fold_info = nil
  M.context.cursor_surrounding = nil
  M.context.quickfix_loclist = nil
  M.context.macros = nil
  M.context.terminal_buffers = nil
  M.context.session_duration = nil
  M.context.vectorcode_snippets = nil
end

function M.load()
  local now = vim.uv.now()
  local current_buf = vim.api.nvim_get_current_buf()
  local current_changedtick = vim.b[current_buf].changedtick or 0
  if cache.timestamp > 0 and now - cache.timestamp < 500 and current_changedtick == cache.last_changedtick then
    if cache.data then
      M.context = vim.deepcopy(cache.data)
    end
    return
  end
  if util.is_current_buf_a_file() then
    local current_file = M.get_current_file()
    local cursor_data = M.get_current_cursor_data()

    M.context.current_file = current_file
    M.context.cursor_data = cursor_data
    M.context.linter_errors = M.check_linter_errors()
  end

  local current_selection = M.get_current_selection()
  if current_selection then
    local selection = M.new_selection(M.context.current_file, current_selection.text, current_selection.lines)
    M.add_selection(selection)
  end

  -- Load lightweight context types immediately
  M.context.marks = M.get_marks()
  M.context.jumplist = M.get_jumplist()
  M.context.undo_history = M.get_undo_history()
  M.context.windows_tabs = M.get_windows_tabs()
  M.context.session_info = M.get_session_info()
  M.context.registers = M.get_registers()
  M.context.command_history = M.get_command_history()
  M.context.search_history = M.get_search_history()
  M.context.debug_data = M.get_debug_data()
  M.context.fold_info = M.get_fold_info()
  M.context.cursor_surrounding = M.get_cursor_surrounding()
  M.context.quickfix_loclist = M.get_quickfix_loclist()
  M.context.macros = M.get_macros()
  M.context.terminal_buffers = M.get_terminal_buffers()
  M.context.session_duration = M.get_session_duration()

  -- Defer heavy context types to prevent UI freeze
  vim.defer_fn(function()
    M.get_recent_buffers(function(result)
      M.context.recent_buffers = result
    end)
    M.context.highlights = M.get_highlights() -- Keep sync, as it's fast with cache
    M.get_lsp_context(function(result)
      M.context.lsp_context = result
    end)
    M.get_plugin_versions(function(result)
      M.context.plugin_versions = result
    end)
    M.get_git_info(function(result)
      M.context.git_info = result
    end)
    M.get_vectorcode_snippets(function(result)
      M.context.vectorcode_snippets = result
    end)
  end, 0)
end

function M.check_linter_errors()
  local diagnostic_conf = config.context and config.context.diagnostics
  if not diagnostic_conf then
    return nil
  end
  local severity_levels = {}
  if diagnostic_conf.error then
    table.insert(severity_levels, vim.diagnostic.severity.ERROR)
  end
  if diagnostic_conf.warning then
    table.insert(severity_levels, vim.diagnostic.severity.WARN)
  end
  if diagnostic_conf.info then
    table.insert(severity_levels, vim.diagnostic.severity.INFO)
  end

  local diagnostics = vim.diagnostic.get(0, { severity = severity_levels })
  if #diagnostics == 0 then
    return nil
  end

  local lines = { 'Found ' .. #diagnostics .. ' error' .. (#diagnostics > 1 and 's' or '') .. ':' }

  for _, diagnostic in ipairs(diagnostics) do
    local line_number = diagnostic.lnum + 1
    local short_message = diagnostic.message:gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', '')
    table.insert(lines, string.format(' Line %d: %s', line_number, short_message))
  end

  return table.concat(lines, '\n')
end

function M.new_selection(file, content, lines)
  return {
    file = file,
    content = util.indent_code_block(content),
    lines = lines,
  }
end

function M.add_selection(selection)
  if not M.context.selections then
    M.context.selections = {}
  end

  table.insert(M.context.selections, selection)
end

function M.add_file(file)
  if not M.context.mentioned_files then
    M.context.mentioned_files = {}
  end

  if vim.fn.filereadable(file) ~= 1 then
    vim.notify('File not added to context. Could not read.')
    return
  end

  file = vim.fn.fnamemodify(file, ':p')

  if not vim.tbl_contains(M.context.mentioned_files, file) then
    table.insert(M.context.mentioned_files, file)
  end
end

M.clear_files = function()
  M.context.mentioned_files = nil
  M.context.mentioned_files_content = nil
end

function M.add_subagent(subagent)
  if not M.context.mentioned_subagents then
    M.context.mentioned_subagents = {}
  end

  if not vim.tbl_contains(M.context.mentioned_subagents, subagent) then
    table.insert(M.context.mentioned_subagents, subagent)
  end
end

M.clear_subagents = function()
  M.context.mentioned_subagents = nil
end

---@param opts OpencodeContextConfig
function M.delta_context(opts)
  opts = opts or config.context
  if opts.enabled == false then
    return {
      current_file = nil,
      mentioned_files = nil,
      selections = nil,
      linter_errors = nil,
      cursor_data = nil,
      mentioned_subagents = nil,
      marks = nil,
      jumplist = nil,
      recent_buffers = nil,
      undo_history = nil,
      windows_tabs = nil,
      highlights = nil,
      session_info = nil,
      registers = nil,
      command_history = nil,
      search_history = nil,
      debug_data = nil,
      lsp_context = nil,
      plugin_versions = nil,
      git_info = nil,
      fold_info = nil,
      cursor_surrounding = nil,
      quickfix_loclist = nil,
      macros = nil,
      terminal_buffers = nil,
      session_duration = nil,
    }
  end

  local context = vim.deepcopy(M.context)
  local last_context = state.last_sent_context
  if not last_context then
    return context
  end

  -- no need to send file context again
  if
    context.current_file
    and last_context.current_file
    and context.current_file.name == last_context.current_file.name
  then
    context.current_file = nil
  end

  -- no need to send subagents again
  if
    context.mentioned_subagents
    and last_context.mentioned_subagents
    and vim.deep_equal(context.mentioned_subagents, last_context.mentioned_subagents)
  then
    context.mentioned_subagents = nil
  end

  return context
end

function M.get_current_file()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.current_file
      and config.context.current_file.enabled
    )
  then
    return nil
  end
  local file = vim.fn.expand('%:p')
  if not file or file == '' or vim.fn.filereadable(file) ~= 1 then
    return nil
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local result = {
    path = filter_path_privacy(file),
    name = vim.fn.fnamemodify(file, ':t'),
    extension = vim.fn.fnamemodify(file, ':e'),
  }

  -- Add filetype if available
  local filetype = vim.bo[bufnr].filetype
  if filetype and filetype ~= '' then
    result.filetype = filetype
  end

  -- Add LSP client names if available
  local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
  if #clients > 0 then
    result.lsp_clients = {}
    for _, client in ipairs(clients) do
      table.insert(result.lsp_clients, client.name)
    end
  end

  return result
end

function M.get_current_cursor_data()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.cursor_data
      and config.context.cursor_data.enabled
    )
  then
    return nil
  end

  local cursor_pos = vim.fn.getcurpos()
  local cursor_content = vim.trim(vim.api.nvim_get_current_line())
  return { line = cursor_pos[2], col = cursor_pos[3], line_content = cursor_content }
end

function M.get_current_selection()
  if
    not (config.context and config.context.enabled and config.context.selection and config.context.selection.enabled)
  then
    return nil
  end
  -- Return nil if not in a visual mode
  if not vim.fn.mode():match('[vV\022]') then
    return nil
  end

  -- Save current position and register state
  local current_pos = vim.fn.getpos('.')
  local old_reg = vim.fn.getreg('x')
  local old_regtype = vim.fn.getregtype('x')

  -- Capture selection text and position
  vim.cmd('normal! "xy')
  local text = vim.fn.getreg('x')

  -- Get line numbers
  vim.cmd('normal! `<')
  local start_line = vim.fn.line('.')
  vim.cmd('normal! `>')
  local end_line = vim.fn.line('.')

  -- Restore state
  vim.fn.setreg('x', old_reg, old_regtype)
  vim.cmd('normal! gv')
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', true)
  vim.fn.setpos('.', current_pos)

  return {
    text = text and text:match('[^%s]') and text or nil,
    lines = start_line .. ', ' .. end_line,
  }
end

-- Get marks (10 most recent)
function M.get_marks()
  if not (config.context and config.context.enabled and config.context.marks and config.context.marks.enabled) then
    return nil
  end

  local marks = vim.fn.getmarklist()
  local limit = config.context.marks.limit or 10
  local result = {}

  for i = 1, math.min(#marks, limit) do
    local mark = marks[i]
    if mark.mark and mark.pos then
      local file = vim.fn.fnamemodify(mark.file or vim.fn.bufname(mark.pos[1] or 0), ':p')
      table.insert(result, {
        mark = mark.mark,
        line = mark.pos[2],
        col = mark.pos[3],
        file = file,
      })
    end
  end

  return #result > 0 and result or nil
end

-- Get jumplist (last 10 jumps)
function M.get_jumplist()
  if
    not (config.context and config.context.enabled and config.context.jumplist and config.context.jumplist.enabled)
  then
    return nil
  end

  local ok, jumplist, current = pcall(vim.fn.getjumplist)
  if not ok or type(jumplist) ~= 'table' then
    return nil
  end
  local limit = config.context.jumplist.limit or 10
  local result = {}

  -- Get the most recent jumps
  local start_idx = math.max(1, #jumplist - limit + 1)
  for i = start_idx, #jumplist do
    local jump = jumplist[i]
    if type(jump) == 'table' and jump.bufnr and jump.lnum then
      table.insert(result, {
        bufnr = jump.bufnr,
        filename = filter_path_privacy(vim.fn.bufname(jump.bufnr)),
        line = jump.lnum,
        col = jump.col,
      })
    end
  end

  return #result > 0 and { jumps = result, current = current } or nil
end

-- Get recent buffers - unified function supporting both legacy and new API
-- Legacy API (no args): returns array of buffer info
-- New API (prompt, opts): returns OpencodeMessagePart[] for synthetic context

-- Get undo history (last 10 branches/changesets)
function M.get_undo_history()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.undo_history
      and config.context.undo_history.enabled
    )
  then
    return nil
  end

  local ok, undotree = pcall(vim.fn.undotree)
  if not ok or not undotree or not undotree.entries then
    return nil
  end

  local limit = config.context.undo_history.limit or 10
  local result = {}

  -- Get the most recent entries
  local start_idx = math.max(1, #undotree.entries - limit + 1)
  for i = start_idx, #undotree.entries do
    local entry = undotree.entries[i]
    table.insert(result, {
      seq = entry.seq,
      time = entry.time,
      newhead = entry.newhead,
    })
  end

  -- Check if current buffer has unsaved changes
  local bufnr = vim.api.nvim_get_current_buf()
  local has_unsaved_changes = vim.bo[bufnr].modified

  -- Count total unsaved changes across all buffers
  local unsaved_buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      local bufname = vim.api.nvim_buf_get_name(buf)
      if bufname and bufname ~= '' then
        table.insert(unsaved_buffers, {
          bufnr = buf,
          name = filter_path_privacy(bufname),
        })
      end
    end
  end

  return #result > 0
      and {
        entries = result,
        seq_cur = undotree.seq_cur,
        current_buffer_modified = has_unsaved_changes,
        unsaved_buffers = #unsaved_buffers > 0 and unsaved_buffers or nil,
      }
    or nil
end

-- Get window and tab context
function M.get_windows_tabs()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.windows_tabs
      and config.context.windows_tabs.enabled
    )
  then
    return nil
  end

  local windows = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    local filename = vim.fn.bufname(bufnr)
    if is_in_cwd(filename) or filename == '' then -- Include empty buffers
      table.insert(windows, {
        id = win,
        bufnr = bufnr,
        filename = filter_path_privacy(filename),
      })
    end
  end

  local tabs = {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    table.insert(tabs, {
      id = tab,
      windows = vim.api.nvim_tabpage_list_wins(tab),
    })
  end

  return { windows = windows, tabs = tabs, current_win = vim.api.nvim_get_current_win() }
end

-- Get buffer line highlights
function M.get_highlights()
  if
    not (config.context and config.context.enabled and config.context.highlights and config.context.highlights.enabled)
  then
    return nil
  end

  -- Cache based on buffer and changedtick to invalidate on buffer changes
  local bufnr = vim.api.nvim_get_current_buf()
  local changedtick = vim.b[bufnr].changedtick or 0
  local cache_key = 'highlights_' .. bufnr .. '_' .. changedtick
  local cached = context_cache.get(cache_key, get_cache_ttl('highlights', 2000))
  if cached then
    return cached
  end

  local matches = vim.fn.getmatches()
  local result = {}

  for _, match in ipairs(matches) do
    table.insert(result, {
      group = match.group,
      pattern = match.pattern,
      priority = match.priority,
    })
  end

  -- Also get extmarks from current buffer if available
  local ok, extmarks = pcall(vim.api.nvim_buf_get_extmarks, bufnr, -1, 0, -1, { details = true })
  if ok and extmarks then
    for _, extmark in ipairs(extmarks) do
      if extmark[4] and extmark[4].hl_group then
        table.insert(result, {
          id = extmark[1],
          line = extmark[2],
          col = extmark[3],
          hl_group = extmark[4].hl_group,
        })
      end
    end
  end

  local final_result = #result > 0 and result or nil
  context_cache.set(cache_key, final_result)
  return final_result
end

-- Get session information
function M.get_session_info()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.session_info
      and config.context.session_info.enabled
    )
  then
    return nil
  end

  local session_name = vim.v.this_session
  if session_name and session_name ~= '' then
    return {
      name = session_name,
      cwd = vim.fn.getcwd(),
    }
  end

  return nil
end

-- Get registers
function M.get_registers()
  if
    not (config.context and config.context.enabled and config.context.registers and config.context.registers.enabled)
  then
    return nil
  end

  local include = config.context.registers.include or { '"', '/', 'q' }
  local result = {}

  for _, reg in ipairs(include) do
    local contents = vim.fn.getreg(reg)
    local regtype = vim.fn.getregtype(reg)
    if contents and contents ~= '' then
      -- Filter out registers containing secrets
      if not contains_secret(contents) then
        result[reg] = {
          contents = contents,
          regtype = regtype,
        }
      else
        result[reg] = {
          contents = '[REDACTED: Potential secret detected]',
          regtype = regtype,
        }
      end
    end
  end

  return vim.tbl_count(result) > 0 and result or nil
end

-- Get command history
function M.get_command_history()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.command_history
      and config.context.command_history.enabled
    )
  then
    return nil
  end

  local limit = config.context.command_history.limit or 5
  local result = {}

  -- Get the last N commands
  for i = -1, -limit, -1 do
    local cmd = vim.fn.histget('cmd', i)
    if cmd and cmd ~= '' then
      table.insert(result, cmd)
    end
  end

  return #result > 0 and result or nil
end

-- Get search history
function M.get_search_history()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.search_history
      and config.context.search_history.enabled
    )
  then
    return nil
  end

  local limit = config.context.search_history.limit or 5
  local result = {}

  -- Get the last N searches
  for i = -1, -limit, -1 do
    local search = vim.fn.histget('/', i)
    if search and search ~= '' then
      table.insert(result, search)
    end
  end

  return #result > 0 and result or nil
end

-- Get debug data (nvim-dap)
function M.get_debug_data()
  if
    not (config.context and config.context.enabled and config.context.debug_data and config.context.debug_data.enabled)
  then
    return nil
  end

  local ok, dap = pcall(require, 'dap')
  if not ok then
    return nil
  end

  local session = dap.session()
  if not session then
    return nil
  end

  local breakpoints = dap.breakpoints.get()
  local result = {
    session_active = true,
    breakpoints = {},
  }

  for buf, bps in pairs(breakpoints) do
    local bufname = vim.fn.bufname(buf)
    for _, bp in ipairs(bps) do
      table.insert(result.breakpoints, {
        file = bufname,
        line = bp.line,
        condition = bp.condition,
      })
    end
  end

  return result
end

-- Get LSP context
function M.get_lsp_context()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.lsp_context
      and config.context.lsp_context.enabled
    )
  then
    return nil
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local result = {}

  -- Get diagnostics with more details
  local diagnostics = vim.diagnostic.get(bufnr) or {}
  local limit = config.context.lsp_context.diagnostics_limit or 10

  result.diagnostics = {}
  for i = 1, math.min(#diagnostics, limit) do
    local diag = diagnostics[i]
    table.insert(result.diagnostics, {
      line = diag.lnum,
      col = diag.col,
      severity = diag.severity,
      message = diag.message,
      source = diag.source,
      code = diag.code,
      user_data = vim.inspect(diag.user_data), -- Add variables/context if available
    })
  end

  -- Get code actions if enabled
  if config.context.lsp_context.code_actions then
    result.code_actions_available = false
    -- Note: Getting code actions is async, so we just note if LSP is available
    local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
    if #clients > 0 then
      result.code_actions_available = true
      result.lsp_clients = {}
      for _, client in ipairs(clients) do
        table.insert(result.lsp_clients, {
          name = client.name,
          id = client.id,
          root_dir = client.config.root_dir,
        })
      end
    end
  end

  -- Get document symbols
  local params = vim.lsp.util.make_position_params()
  local ok_sym, symbols_resp = pcall(vim.lsp.buf_request_sync, bufnr, 'textDocument/documentSymbol', params, 1000)
  if ok_sym and symbols_resp and symbols_resp[1] and symbols_resp[1].result then
    local symbols = symbols_resp[1].result
    local flat_symbols = {}
    local function flatten(s)
      -- Filter out structural noise symbols (e.g., "[1]", "[2]", etc.)
      if s.name and not s.name:match('^%[%d+%]$') then
        table.insert(flat_symbols, {
          name = s.name,
          kind = s.kind,
          range = s.range or { start = { 0, 0 }, ['end'] = { 0, 0 } },
          detail = s.detail or '',
        })
      end
      if s.children then
        for _, c in ipairs(s.children) do
          flatten(c)
        end
      end
    end
    for _, s in ipairs(symbols) do
      flatten(s)
    end
    if #flat_symbols > 20 then
      flat_symbols = vim.list_slice(flat_symbols, 1, 20)
    end
    result.symbols = flat_symbols
  end

  return (#result.diagnostics > 0 or result.code_actions_available or (result.symbols and #result.symbols > 0))
      and result
    or nil
end

-- Get Git information (async)
---@param callback function(result: table|nil)
function M.get_git_info(callback)
  if
    not (config.context and config.context.enabled and config.context.git_info and config.context.git_info.enabled)
  then
    callback(nil)
    return
  end

  -- Check cache first
  local cache_key = 'git_info'
  local cached = context_cache.get(cache_key, get_cache_ttl('git_info', 5000))
  if cached then
    callback(cached)
    return
  end

  -- Run git commands in parallel using context_cache.parallel
  local tasks = {
    { name = 'branch', cmd = { 'git', 'rev-parse', '--abbrev-ref', 'HEAD' } },
    { name = 'sha', cmd = { 'git', 'rev-parse', '--short', 'HEAD' } },
    { name = 'status', cmd = { 'git', 'status', '--porcelain' } },
    { name = 'log', cmd = { 'git', 'log', '--oneline', '-n', tostring(config.context.git_info.changes_limit or 5) } },
  }

  -- Add file diff if applicable
  local current_file = vim.fn.expand('%:p')
  if current_file and current_file ~= '' and is_in_cwd(current_file) then
    table.insert(tasks, {
      name = 'diff',
      cmd = { 'git', 'diff', 'HEAD', '--', current_file },
    })
  end

  context_cache.parallel(tasks, function(results)
    if not results.branch or results.branch == '' then
      callback(nil)
      return
    end

    local result = {
      branch = results.branch,
      head_sha = results.sha,
      is_dirty = results.status and #vim.split(results.status, '\n', { plain = true }) > 0,
    }

    -- Parse status for staged/unstaged counts
    if results.status then
      local staged_count = 0
      local unstaged_count = 0
      for line in results.status:gmatch('[^\n]+') do
        if line ~= '' then
          local index_status = line:sub(1, 1)
          local work_status = line:sub(2, 2)
          if index_status ~= ' ' and index_status ~= '?' then
            staged_count = staged_count + 1
          end
          if work_status ~= ' ' then
            unstaged_count = unstaged_count + 1
          end
        end
      end
      if staged_count > 0 then
        result.staged_changes = staged_count
      end
      if unstaged_count > 0 then
        result.unstaged_changes = unstaged_count
      end
    end

    -- Parse diff
    if results.diff then
      local diff_limit = config.context.git_info.diff_limit or 10
      result.file_diff = {}
      local lines = vim.split(results.diff, '\n', { plain = true })
      for i = 1, math.min(#lines, diff_limit) do
        table.insert(result.file_diff, lines[i])
      end
    end

    -- Parse log
    if results.log then
      result.recent_changes = vim.split(results.log, '\n', { plain = true })
    end

    -- Cache and callback
    context_cache.set(cache_key, result)
    callback(result)
  end, { timeout = 5000 })
end

-- Get plugin versions from lazy-lock.json (async)
---@param callback function(result: table|nil)
function M.get_plugin_versions(callback)
  if
    not (
      config.context
      and config.context.enabled
      and config.context.plugin_versions
      and config.context.plugin_versions.enabled
    )
  then
    callback(nil)
    return
  end

  local lock_path = vim.fn.stdpath('data') .. '/lazy/lazy-lock.json'
  if vim.fn.filereadable(lock_path) ~= 1 then
    callback(nil)
    return
  end

  -- Check cache first with file modification time
  local cache_key = 'plugin_versions'
  local stat = vim.loop.fs_stat(lock_path)
  local lock_mtime = stat and stat.mtime.sec or 0

  -- Use cache key with mtime to invalidate on file change
  local cache_key_with_mtime = cache_key .. '_' .. lock_mtime
  local cached = context_cache.get(cache_key_with_mtime, get_cache_ttl('plugin_versions', 60000))
  if cached then
    callback(cached)
    return
  end

  -- Clear old cache entries for this section
  context_cache.clear(cache_key)

  -- Read file asynchronously
  vim.defer_fn(function()
    local ok, content = pcall(vim.fn.readfile, lock_path)
    if not ok then
      callback(nil)
      return
    end

    local ok_decode, data = pcall(vim.json.decode, table.concat(content, '\n'))
    if not ok_decode or type(data) ~= 'table' or not data.packages then
      callback(nil)
      return
    end

    local result = {}
    local limit = config.context.plugin_versions.limit or 20
    local count = 0

    for name, info in pairs(data.packages) do
      if count >= limit then
        break
      end
      table.insert(result, {
        name = name,
        version = info.version or 'unknown',
        commit = info.commit and string.sub(info.commit, 1, 8) or 'none',
      })
      count = count + 1
    end

    local final_result = #result > 0 and result or nil
    context_cache.set(cache_key_with_mtime, final_result)
    callback(final_result)
  end, 0)
end

-- Get fold information
function M.get_fold_info()
  if
    not (config.context and config.context.enabled and config.context.fold_info and config.context.fold_info.enabled)
  then
    return nil
  end

  local result = {}
  local win = vim.api.nvim_get_current_win()
  local top = vim.fn.line('w0')
  local bottom = vim.fn.line('w$')

  for lnum = top, bottom do
    local fold_level = vim.fn.foldlevel(lnum)
    local fold_closed = vim.fn.foldclosed(lnum)

    if fold_level > 0 and fold_closed ~= -1 then
      table.insert(result, {
        line = lnum,
        level = fold_level,
        closed = true,
        closed_start = fold_closed,
      })
    end
  end

  return #result > 0 and result or nil
end

-- Get cursor surrounding context
function M.get_cursor_surrounding()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.cursor_surrounding
      and config.context.cursor_surrounding.enabled
    )
  then
    return nil
  end

  local lines_above = config.context.cursor_surrounding.lines_above or 3
  local lines_below = config.context.cursor_surrounding.lines_below or 3

  local current_line = vim.fn.line('.')
  local start_line = math.max(1, current_line - lines_above)
  local end_line = math.min(vim.fn.line('$'), current_line + lines_below)

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, 0, start_line - 1, end_line, false)
  if not ok then
    return nil
  end

  return {
    lines = lines,
    start_line = start_line,
    end_line = end_line,
    current_line = current_line,
  }
end

-- Get quickfix and location list
function M.get_quickfix_loclist()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.quickfix_loclist
      and config.context.quickfix_loclist.enabled
    )
  then
    return nil
  end

  local limit = config.context.quickfix_loclist.limit or 5
  local result = {}

  -- Get quickfix list
  local qflist = vim.fn.getqflist()
  result.quickfix = {}
  for i = 1, math.min(#qflist, limit) do
    local item = qflist[i]
    table.insert(result.quickfix, {
      filename = filter_path_privacy(vim.fn.bufname(item.bufnr)),
      lnum = item.lnum,
      col = item.col,
      text = item.text,
      type = item.type,
    })
  end

  -- Get location list
  local loclist = vim.fn.getloclist(0)
  result.loclist = {}
  for i = 1, math.min(#loclist, limit) do
    local item = loclist[i]
    table.insert(result.loclist, {
      filename = filter_path_privacy(vim.fn.bufname(item.bufnr)),
      lnum = item.lnum,
      col = item.col,
      text = item.text,
      type = item.type,
    })
  end

  return (#result.quickfix > 0 or #result.loclist > 0) and result or nil
end

-- Get macros
function M.get_macros()
  if not (config.context and config.context.enabled and config.context.macros and config.context.macros.enabled) then
    return nil
  end

  local register = config.context.macros.register or 'q'
  local macro = vim.fn.getreg(register)

  if macro and macro ~= '' then
    return {
      register = register,
      content = macro,
    }
  end

  return nil
end

-- Get terminal buffers
function M.get_terminal_buffers()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.terminal_buffers
      and config.context.terminal_buffers.enabled
    )
  then
    return nil
  end

  local result = {}
  local buffers = vim.fn.getbufinfo({ buflisted = true })

  -- Sort by last used
  table.sort(buffers, function(a, b)
    return (a.lastused or 0) > (b.lastused or 0)
  end)

  for _, buf in ipairs(buffers) do
    local name = buf.name
    if name and name:match('^term://') then
      table.insert(result, {
        bufnr = buf.bufnr,
        name = name,
        lastused = buf.lastused,
      })
      break -- Only get the most recent
    end
  end

  return #result > 0 and result or nil
end

-- Get session duration
function M.get_session_duration()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.session_duration
      and config.context.session_duration.enabled
    )
  then
    return nil
  end

  local current_time = vim.loop.hrtime()
  local duration_ns = current_time - M.session_start_time
  local duration_seconds = duration_ns / 1e9

  return {
    duration_seconds = math.floor(duration_seconds),
    duration_minutes = math.floor(duration_seconds / 60),
    duration_hours = math.floor(duration_seconds / 3600),
  }
end

-- Get VectorCode snippets (async)
---@param callback function(result: table|nil)
function M.get_vectorcode_snippets(callback)
  if
    not (
      config.context
      and config.context.enabled
      and config.context.vectorcode_snippets
      and config.context.vectorcode_snippets.enabled
    )
  then
    callback(nil)
    return
  end

  -- Check if VectorCode is available
  local ok, vectorcode = pcall(require, 'vectorcode')
  if not ok then
    callback(nil)
    return
  end

  -- Get current file and cursor data for better query
  local current_file = M.get_current_file()
  local cursor_data = M.get_current_cursor_data()
  local current_selection = M.get_current_selection()

  if not current_file or not current_file.path then
    callback(nil)
    return
  end

  -- Build a more relevant query based on context
  local query_strategy = config.context.vectorcode_snippets.query_strategy or 'auto'
  local query_parts = {}

  if
    query_strategy == 'selection'
    and current_selection
    and current_selection.text
    and current_selection.text:match('%S')
  then
    table.insert(query_parts, current_selection.text)
  elseif
    query_strategy == 'line'
    and cursor_data
    and cursor_data.line_content
    and cursor_data.line_content:match('%S')
  then
    table.insert(query_parts, cursor_data.line_content)
  elseif query_strategy == 'filename' then
    table.insert(query_parts, vim.fn.fnamemodify(current_file.path, ':t'))
    if current_file.filetype then
      table.insert(query_parts, current_file.filetype)
    end
  else -- 'auto' or fallback
    -- Use current selection if available (most specific)
    if current_selection and current_selection.text and current_selection.text:match('%S') then
      table.insert(query_parts, current_selection.text)
    elseif cursor_data and cursor_data.line_content and cursor_data.line_content:match('%S') then
      -- Use current line content
      table.insert(query_parts, cursor_data.line_content)
    else
      -- Fallback to filename + filetype
      table.insert(query_parts, vim.fn.fnamemodify(current_file.path, ':t'))
      if current_file.filetype then
        table.insert(query_parts, current_file.filetype)
      end
    end
  end

  -- Add filetype for better context if not already included and strategy allows
  if
    current_file.filetype
    and query_strategy ~= 'selection'
    and not vim.tbl_contains(query_parts, current_file.filetype)
  then
    table.insert(query_parts, current_file.filetype)
  end

  local query = table.concat(query_parts, ' ')
  local n = config.context.vectorcode_snippets.n or 3

  -- Ensure query is not empty and not too long
  if query == '' or #query > 500 then
    callback(nil)
    return
  end

  -- Query VectorCode asynchronously
  vim.defer_fn(function()
    local ok_query, results = pcall(vectorcode.query, query, { n = n })
    if not ok_query or not results then
      callback(nil)
      return
    end

    -- Format results
    local snippets = {}
    for _, result in ipairs(results) do
      table.insert(snippets, {
        path = result.path,
        content = result.document,
      })
    end

    callback(#snippets > 0 and snippets or nil)
  end, 0)
end

local function format_file_part(path, prompt)
  local rel_path = vim.fn.fnamemodify(path, ':~:.')
  local mention = '@' .. rel_path
  local pos = prompt and prompt:find(mention)
  pos = pos and pos - 1 or 0 -- convert to 0-based index

  local file_part = { filename = rel_path, type = 'file', mime = 'text/plain', url = 'file://' .. path }
  if prompt then
    file_part.source = {
      path = path,
      type = 'file',
      text = { start = pos, value = mention, ['end'] = pos + #mention - 1 },
    }
  end
  return file_part
end

---@param selection OpencodeContextSelection
local function format_selection_part(selection)
  local lang = selection.file and selection.file.extension or ''

  return {
    type = 'text',
    text = vim.json.encode({
      context_type = 'selection',
      file = selection.file,
      content = string.format('```%s\n%s\n```', lang, selection.content),
      lines = selection.lines,
    }),
    synthetic = true,
  }
end

local function format_diagnostics_part(diagnostics)
  return {
    type = 'text',
    text = vim.json.encode({ context_type = 'diagnostics', content = diagnostics }),
    synthetic = true,
  }
end

local function format_cursor_data_part(cursor_data)
  return {
    type = 'text',
    text = vim.json.encode({ context_type = 'cursor-data', line = cursor_data.line, column = cursor_data.column }),
    synthetic = true,
  }
end

-- Format functions for new context types
local function format_context_part(context_type, content)
  return {
    type = 'text',
    text = vim.json.encode({ context_type = context_type, content = content }),
    synthetic = true,
  }
end

local function format_subagents_part(agent, prompt)
  local mention = '@' .. agent
  local pos = prompt:find(mention)
  pos = pos and pos - 1 or 0 -- convert to 0-based index

  return {
    type = 'agent',
    name = agent,
    source = { value = mention, start = pos, ['end'] = pos + #mention },
  }
end

--- Formats a prompt and context into message with parts for the opencode API
---@param prompt string
---@param opts? OpencodeContextConfig|nil
---@return OpencodeMessagePart[]
function M.format_message(prompt, opts)
  opts = opts or config.context
  local context = M.delta_context(opts)
  context.prompt = prompt

  local parts = { { type = 'text', text = prompt } }

  -- recent_buffers synthetic context
  if config.context and config.context.recent_buffers and config.context.recent_buffers.enabled then
    local ok, recent = pcall(M.get_recent_buffers, prompt, config.context.recent_buffers)
    if ok and recent and #recent > 0 then
      for _, rb in ipairs(recent) do
        table.insert(parts, rb)
      end
    end
  end

  for _, path in ipairs(context.mentioned_files or {}) do
    table.insert(parts, format_file_part(path, prompt))
  end

  for _, agent in ipairs(context.mentioned_subagents or {}) do
    table.insert(parts, format_subagents_part(agent, prompt))
  end

  if context.current_file then
    table.insert(parts, format_file_part(context.current_file.path))
  end

  for _, sel in ipairs(context.selections or {}) do
    table.insert(parts, format_selection_part(sel))
  end

  if context.linter_errors then
    table.insert(parts, format_diagnostics_part(context.linter_errors))
  end

  if context.cursor_data then
    table.insert(parts, format_cursor_data_part(context.cursor_data))
  end

  -- Add new context types
  if context.marks then
    table.insert(parts, format_context_part('marks', context.marks))
  end

  if context.jumplist then
    table.insert(parts, format_context_part('jumplist', context.jumplist))
  end

  if context.recent_buffers then
    table.insert(parts, format_context_part('recent_buffers', context.recent_buffers))
  end

  if context.undo_history then
    table.insert(parts, format_context_part('undo_history', context.undo_history))
  end

  if context.windows_tabs then
    table.insert(parts, format_context_part('windows_tabs', context.windows_tabs))
  end

  if context.highlights then
    table.insert(parts, format_context_part('highlights', context.highlights))
  end

  if context.session_info then
    table.insert(parts, format_context_part('session_info', context.session_info))
  end

  if context.registers then
    table.insert(parts, format_context_part('registers', context.registers))
  end

  if context.command_history then
    table.insert(parts, format_context_part('command_history', context.command_history))
  end

  if context.search_history then
    table.insert(parts, format_context_part('search_history', context.search_history))
  end

  if context.debug_data then
    table.insert(parts, format_context_part('debug_data', context.debug_data))
  end

  if context.lsp_context then
    table.insert(parts, format_context_part('lsp_context', context.lsp_context))
  end

  if context.plugin_versions then
    table.insert(parts, format_context_part('plugin_versions', context.plugin_versions))
  end

  if context.git_info then
    table.insert(parts, format_context_part('git_info', context.git_info))
  end

  if context.fold_info then
    table.insert(parts, format_context_part('fold_info', context.fold_info))
  end

  if context.cursor_surrounding then
    table.insert(parts, format_context_part('cursor_surrounding', context.cursor_surrounding))
  end

  if context.quickfix_loclist then
    table.insert(parts, format_context_part('quickfix_loclist', context.quickfix_loclist))
  end

  if context.macros then
    table.insert(parts, format_context_part('macros', context.macros))
  end

  if context.terminal_buffers then
    table.insert(parts, format_context_part('terminal_buffers', context.terminal_buffers))
  end

  if context.session_duration then
    table.insert(parts, format_context_part('session_duration', context.session_duration))
  end

  if context.vectorcode_snippets then
    table.insert(parts, format_context_part('vectorcode_snippets', context.vectorcode_snippets))
  end

  return parts
end

---@param part OpencodeMessagePart
---@param context_type string|nil
local function decode_json_context(part, context_type)
  local ok, result = pcall(vim.json.decode, part.text)
  if not ok or (context_type and result.context_type ~= context_type) then
    return nil
  end
  return result
end

--- Extracts context from an OpencodeMessage (with parts)
---@param message { parts: OpencodeMessagePart[] }
---@return { prompt: string, selected_text: string|nil, current_file: string|nil, mentioned_files: string[]|nil}
function M.extract_from_opencode_message(message)
  local ctx = { prompt = nil, selected_text = nil, current_file = nil }

  local handlers = {
    text = function(part)
      ctx.prompt = ctx.prompt or part.text or ''
    end,
    text_context = function(part)
      local json = decode_json_context(part, 'selection')
      ctx.selected_text = json and json.content or ctx.selected_text
    end,
    file = function(part)
      if not part.source then
        ctx.current_file = part.filename
      end
    end,
  }

  for _, part in ipairs(message and message.parts or {}) do
    local handler = handlers[part.type .. (part.synthetic and '_context' or '')]
    if handler then
      handler(part)
    end

    if ctx.prompt and ctx.selected_text and ctx.current_file then
      break
    end
  end

  return ctx
end

function M.extract_from_message_legacy(text)
  local current_file = M.extract_legacy_tag('current-file', text)
  local context = {
    prompt = M.extract_legacy_tag('user-query', text) or text,
    selected_text = M.extract_legacy_tag('manually-added-selection', text),
    current_file = current_file and current_file:match('Path: (.+)') or nil,
  }
  return context
end

function M.extract_legacy_tag(tag, text)
  local start_tag = '<' .. tag .. '>'
  local end_tag = '</' .. tag .. '>'

  -- Use pattern matching to find the content between the tags
  -- Make search start_tag and end_tag more robust with pattern escaping
  local pattern = vim.pesc(start_tag) .. '(.-)' .. vim.pesc(end_tag)
  local content = text:match(pattern)

  if content then
    return vim.trim(content)
  end

  -- Fallback to the original method if pattern matching fails
  local query_start = text:find(start_tag)
  local query_end = text:find(end_tag)

  if query_start and query_end then
    -- Extract and trim the content between the tags
    local query_content = text:sub(query_start + #start_tag, query_end - 1)
    return vim.trim(query_content)
  end

  return nil
end

---@param buf number
---@return boolean
local function is_valid_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if vim.bo[buf].buftype ~= '' then
    return false
  end
  if not vim.bo[buf].modifiable then
    return false
  end
  return true
end

---@param client table
local function client_supports_symbols(client)
  if not client or not client.server_capabilities then
    return false
  end
  local caps = client.server_capabilities
  return caps.documentSymbolProvider == true or (type(caps.documentSymbolProvider) == 'table')
end

---@param bufnr number
---@return table[]|nil
local function fetch_document_symbols(bufnr)
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local results = {}
  local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
  local any = false
  for _, client in ipairs(clients) do
    if client_supports_symbols(client) then
      any = true
      local ok, resp = pcall(function()
        return client.request_sync('textDocument/documentSymbol', params, 500, bufnr)
      end)
      if ok and resp and resp.result then
        if vim.tbl_islist(resp.result) then
          vim.list_extend(results, resp.result)
        else
          table.insert(results, resp.result)
        end
      end
    end
  end
  if not any or #results == 0 then
    return nil
  end
  return results
end

local function flatten_symbols(symbols, acc, parent)
  acc = acc or {}
  if not symbols then
    return acc
  end
  for _, s in ipairs(symbols) do
    local name = s.name or '<anonymous>'
    local kind = s.kind or 0
    -- Filter out structural noise symbols (e.g., "[1]", "[2]", etc.)
    if not name:match('^%[%d+%]$') then
      table.insert(acc, { name = name, kind = kind, parent = parent })
    end
    if s.children then
      flatten_symbols(s.children, acc, name)
    end
  end
  return acc
end

---Deduplicate symbol names preserving order
---@param names string[]
---@return string[]
local function dedupe_symbol_names(names)
  local seen = {}
  local result = {}
  for _, name in ipairs(names) do
    if not seen[name] then
      seen[name] = true
      table.insert(result, name)
    end
  end
  return result
end

---@param prompt? string
---@param opts? { enabled: boolean, symbols_only: boolean, max: number }
---@return OpencodeMessagePart[]|table[]|nil
function M.get_recent_buffers(prompt, opts)
  -- New API: called with prompt and opts
  if not opts or not opts.enabled then
    return nil
  end

  -- Legacy API: called with no arguments, uses config.context.recent_buffers
  if prompt == nil and opts == nil then
    if
      not (
        config.context
        and config.context.enabled
        and config.context.recent_buffers
        and config.context.recent_buffers.enabled
      )
    then
      return nil
    end

    local buffers = vim.fn.getbufinfo({ buflisted = true })
    local limit = config.context.recent_buffers.limit or 10

    -- Sort by last used time
    table.sort(buffers, function(a, b)
      return (a.lastused or 0) > (b.lastused or 0)
    end)

    local result = {}
    local current_bufnr = vim.fn.bufnr()
    for i = 1, math.min(#buffers, limit) do
      local buf = buffers[i]
      local buf_entry = {
        bufnr = buf.bufnr,
        name = filter_path_privacy(buf.name),
        lastused = buf.lastused,
        changed = buf.changed == 1,
      }

      -- Add filetype if available (only for valid buffers)
      if vim.api.nvim_buf_is_valid(buf.bufnr) then
        local filetype = vim.bo[buf.bufnr].filetype
        if filetype and filetype ~= '' then
          buf_entry.filetype = filetype
        end

        -- Add LSP client names if available
        local clients = vim.lsp.get_active_clients({ bufnr = buf.bufnr })
        if #clients > 0 then
          buf_entry.lsp_clients = {}
          for _, client in ipairs(clients) do
            table.insert(buf_entry.lsp_clients, client.name)
          end
        end

        -- Add cursor_surrounding if this is the current buffer
        if buf.bufnr == current_bufnr then
          local current_line = vim.fn.line('.')
          buf_entry.cursor_surrounding = get_surrounding_lines(buf.bufnr, current_line)
        end
      end

      table.insert(result, buf_entry)
    end

    local recent_conf = config.context.recent_buffers
    if recent_conf and recent_conf.symbols_only then
      for _, buf_entry in ipairs(result) do
        local bufnr = buf_entry.bufnr

        -- Skip if buffer is not valid
        if not vim.api.nvim_buf_is_valid(bufnr) then
          goto continue
        end

        local line_count = vim.api.nvim_buf_line_count(bufnr)
        if line_count <= 100 then
          goto continue
        end

        local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
        if #clients == 0 then
          goto continue
        end

        if vim.api.nvim_buf_get_option(bufnr, 'readonly') or vim.bo[bufnr].buftype ~= '' then
          goto continue
        end

        -- Cache LSP symbols per buffer with changedtick
        local changedtick = vim.b[bufnr].changedtick or 0
        local cache_key = 'lsp_symbols_' .. bufnr .. '_' .. changedtick
        local cached_symbols = context_cache.get(cache_key, get_cache_ttl('lsp_symbols', 10000))

        if cached_symbols then
          buf_entry.symbols = cached_symbols
        else
          local ok, resp = pcall(vim.lsp.buf_request_sync, bufnr, 'textDocument/documentSymbol', {}, 1000)
          if ok and resp and resp[1] and resp[1].result then
            local symbols = resp[1].result
            local flat = {}
            local function flatten(s)
              -- Filter out structural noise symbols (e.g., "[1]", "[2]", etc.)
              -- These are often placeholder symbols from some LSP servers
              if s.name and not s.name:match('^%[%d+%]$') then
                table.insert(flat, {
                  name = s.name,
                  kind = s.kind,
                  range = s.range or { start = { 0, 0 }, ['end'] = { 0, 0 } },
                  detail = s.detail or '',
                })
              end
              if s.children then
                for _, c in ipairs(s.children) do
                  flatten(c)
                end
              end
            end
            for _, s in ipairs(symbols) do
              flatten(s)
            end
            if #flat > 20 then
              flat = vim.list_slice(flat, 1, 20)
            end
            buf_entry.symbols = flat
            context_cache.set(cache_key, flat)
          end
        end
        ::continue::
      end
    end

    return #result > 0 and result or nil
  end

  local bufs = vim.api.nvim_list_bufs()
  local recent = {}

  -- Collect candidate buffers (MRU ordering approximation by number)
  for _, b in ipairs(bufs) do
    if is_valid_buffer(b) then
      local line_count = vim.api.nvim_buf_line_count(b)
      if line_count > 100 then
        local clients = vim.lsp.get_active_clients({ bufnr = b })
        if #clients > 0 then
          table.insert(recent, { bufnr = b, line_count = line_count })
        end
      end
    end
  end

  if #recent == 0 then
    return nil
  end

  table.sort(recent, function(a, b)
    return a.bufnr > b.bufnr -- crude MRU heuristic
  end)

  local max_items = math.max(1, opts.max or 5)
  local parts = {}
  for i = 1, math.min(#recent, max_items) do
    local b = recent[i].bufnr
    local path = vim.api.nvim_buf_get_name(b)
    local rel_path = vim.fn.fnamemodify(path, ':~:.')
    local mention = '@' .. rel_path
    local pos = prompt and prompt:find(mention)
    pos = pos and pos - 1 or 0

    local symbol_list
    if opts.symbols_only then
      local symbols = fetch_document_symbols(b)
      if symbols then
        local flat = flatten_symbols(symbols)
        local names = {}
        for _, s in ipairs(flat) do
          table.insert(names, s.name)
        end
        symbol_list = dedupe_symbol_names(names)
      end
      -- Guarantee a symbols array exists (empty if none found) for a stable contract
      if not symbol_list then
        symbol_list = {}
      end
    end

    local content
    if not opts.symbols_only then
      local first_lines = vim.api.nvim_buf_get_lines(b, 0, math.min(200, vim.api.nvim_buf_line_count(b)), false)
      content = table.concat(first_lines, '\n')
    end

    local data = {
      context_type = 'recent-buffer',
      path = path,
      relative = rel_path,
      line_count = recent[i].line_count,
      symbols = symbol_list,
      preview = content and ('```\n' .. content .. '\n```') or nil,
    }

    local part = {
      type = 'text',
      text = vim.json.encode(data),
      synthetic = true,
      source = {
        path = path,
        type = 'file',
        text = { start = pos, value = mention, ['end'] = pos + #mention - 1 },
      },
    }
    table.insert(parts, part)
  end

  return parts
end

-- Setup cache invalidation autocmds
local function setup_cache_invalidation()
  local group = vim.api.nvim_create_augroup('OpencodeContextCache', { clear = true })

  -- Invalidate git cache on file write (git status might change)
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = '*',
    callback = function()
      context_cache.clear('git_info')
    end,
  })

  -- Clear buffer-specific caches on buffer delete
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = group,
    pattern = '*',
    callback = function(args)
      local bufnr = args.buf
      -- Invalidate any cache keys that include this buffer number
      context_cache.clear('highlights_' .. bufnr)
      context_cache.clear('recent_buffers_' .. bufnr)
    end,
  })
end

-- Initialize cache invalidation
setup_cache_invalidation()

return M
