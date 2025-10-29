local Promise = require('opencode.promise')

local M = {}

--- Enhanced async vectorcode client with multiple query strategies
local VectorCodeAsync = {}
VectorCodeAsync.__index = VectorCodeAsync

function M.new()
  return setmetatable({
    _vectorcode = nil,
    _available = false,
    _init_promise = nil,
  }, VectorCodeAsync)
end

--- Initialize vectorcode module asynchronously
--- @return Promise<boolean> promise indicating if vectorcode is available
function VectorCodeAsync:init()
  if self._init_promise then
    return self._init_promise
  end

  self._init_promise = Promise.new()

  vim.defer_fn(function()
    local ok, vectorcode = pcall(require, 'vectorcode')
    if ok and vectorcode then
      self._vectorcode = vectorcode
      self._available = true
      self._init_promise:resolve(true)
    else
      self._init_promise:resolve(false)
    end
  end, 0)

  return self._init_promise
end

--- Check if vectorcode is available
--- @return boolean
function VectorCodeAsync:is_available()
  return self._available
end

--- Query vectorcode with timeout and cancellation support
--- @param query string Search query
--- @param options table { n?: number, timeout?: number, cancellation_token?: table }
--- @return Promise<table[]> promise
function VectorCodeAsync:query(query, options)
  options = options or {}
  local promise = Promise.new()

  -- Early return if not available
  if not self:is_available() then
    vim.defer_fn(function()
      promise:resolve(nil)
    end, 0)
    return promise
  end

   -- Set up timeout if specified
   local timer = nil
   if options.timeout then
     timer = vim.uv.new_timer()
     timer:start(options.timeout, 0, function()
       if timer and not timer:is_closing() then
         timer:close()
       end
       promise:cancel()
     end)
   end

  -- Perform query asynchronously
   vim.defer_fn(function()
     -- Check cancellation before query
     if options.cancellation_token and options.cancellation_token:is_cancelled() then
       if timer and not timer:is_closing() then timer:close() end
       promise:cancel()
       return
     end

    local ok, results = pcall(self._vectorcode.query, query, { n = options.n or 3 })
    
     -- Clean up timer
     if timer then
       if not timer:is_closing() then
         timer:stop()
         timer:close()
       end
     end

    if not ok or not results then
      promise:resolve(nil)
      return
    end

    -- Format results
    local formatted_results = {}
    for _, result in ipairs(results) do
      table.insert(formatted_results, {
        path = result.path,
        content = result.document,
        score = result.score,
        metadata = result.metadata,
      })
    end

    promise:resolve(#formatted_results > 0 and formatted_results or nil)
  end, 0)

  return promise
end

--- Batch query multiple queries in parallel
--- @param queries table Array of query strings
--- @param options table { n?: number, timeout?: number, on_progress?: function }
--- @return Promise<table[]> promise - array of result arrays
function VectorCodeAsync:batch_query(queries, options)
  options = options or {}
  
  if #queries == 0 then
    return Promise.new():resolve({})
  end

  local promises = {}
  for _, query in ipairs(queries) do
    table.insert(promises, self:query(query, options))
  end

  return Promise.all(promises, options.timeout)
end

--- Stream results as they come in (for large result sets)
--- @param query string Search query
--- @param options table { n?: number, chunk_size?: number, on_chunk?: function }
--- @return Promise<table[]> promise
function VectorCodeAsync:stream_query(query, options)
  options = options or {}
  local promise = Promise.new()
  local results = {}
  local chunk_size = options.chunk_size or 10

  if not self:is_available() then
    vim.defer_fn(function() promise:resolve(nil) end, 0)
    return promise
  end

  -- For now, this is a simplified streaming implementation
  -- In practice, you might want to use a proper async iterator
  vim.defer_fn(function()
    local ok, all_results = pcall(self._vectorcode.query, query, { n = options.n or 50 })
    
    if not ok or not all_results then
      promise:resolve(nil)
      return
    end

    -- Stream results in chunks
    local function stream_next_chunk(start_index)
      local end_index = math.min(start_index + chunk_size, #all_results)
      local chunk = {}
      
      for i = start_index, end_index do
        table.insert(chunk, {
          path = all_results[i].path,
          content = all_results[i].document,
          score = all_results[i].score,
        })
      end
      
      if options.on_chunk then
        options.on_chunk(chunk, start_index, end_index)
      end
      
      if end_index < #all_results then
        vim.defer_fn(function() stream_next_chunk(end_index + 1) end, 0)
      else
        -- Stream complete
        promise:resolve(results)
      end
    end

    -- Start streaming
    stream_next_chunk(1)
  end, 0)

  return promise
end

--- Context-aware query that adapts based on current buffer state
--- @param strategy string 'auto' | 'selection' | 'line' | 'filename' | 'semantic'
--- @param options table { n?: number, timeout?: number }
--- @return Promise<table[]> promise
function VectorCodeAsync:contextual_query(strategy, options)
  strategy = strategy or 'auto'
  options = options or {}

  local current_file = vim.fn.expand('%:p')
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local selection = vim.fn.getpos("'<")
  local selection_end = vim.fn.getpos("'>")
  
  local query_parts = {}

  if strategy == 'selection' or (strategy == 'auto' and selection[3] < selection_end[3]) then
    -- Get visual selection
    local selected_text = vim.fn.getline(selection[2], selection_end[2])
    selected_text = table.concat(selected_text, '\n')
    if selected_text:match('%S') then
      table.insert(query_parts, selected_text)
    end
  elseif strategy == 'line' then
    -- Get current line
    local line_content = vim.fn.getline(cursor_pos[1])
    if line_content:match('%S') then
      table.insert(query_parts, line_content)
    end
  elseif strategy == 'filename' then
    -- Use filename and filetype
    table.insert(query_parts, vim.fn.expand('%:t'))
    local filetype = vim.bo.filetype
    if filetype and filetype ~= '' then
      table.insert(query_parts, filetype)
    end
  elseif strategy == 'semantic' then
    -- More sophisticated semantic query
    local function_node = vim.treesitter.get_node()
    if function_node then
      local start_row, start_col, end_row, end_col = function_node:range()
      local lines = vim.api.nvim_buf_get_lines(0, start_row, end_row + 1, false)
      local function_text = table.concat(lines, '\n')
      table.insert(query_parts, function_text)
    end
  else -- 'auto' strategy
    -- Use the same logic as your current implementation
    if selection[3] < selection_end[3] then
      local selected_text = vim.fn.getline(selection[2], selection_end[2])
      selected_text = table.concat(selected_text, '\n')
      if selected_text:match('%S') then
        table.insert(query_parts, selected_text)
      end
    end
    
    if #query_parts == 0 then
      local line_content = vim.fn.getline(cursor_pos[1])
      if line_content:match('%S') then
        table.insert(query_parts, line_content)
      end
    end
    
    if #query_parts == 0 then
      table.insert(query_parts, vim.fn.expand('%:t'))
      local filetype = vim.bo.filetype
      if filetype and filetype ~= '' then
        table.insert(query_parts, filetype)
      end
    end
  end

  local query = table.concat(query_parts, ' ')
  
  if query == '' or #query > 500 then
    return Promise.new():resolve(nil)
  end

  return self:query(query, options)
end

--- Get completion suggestions based on vectorcode results
--- @param partial_input string Current input to complete
--- @param options table { n?: number, timeout?: number }
--- @return Promise<table[]> promise
function VectorCodeAsync:get_completions(partial_input, options)
  options = options or {}
  
  return self:contextual_query('auto', options):and_then(function(results)
    if not results then
      return nil
    end

    -- Extract relevant completion candidates
    local completions = {}
    for _, result in ipairs(results) do
      -- Look for lines that start with or contain the partial input
      local lines = vim.split(result.content, '\n', { plain = true })
      for _, line in ipairs(lines) do
        if line:find(partial_input, 1, true) == 1 then
          table.insert(completions, {
            word = line,
            path = result.path,
            score = result.score,
          })
        end
      end
    end

    -- Sort by score and limit results
    table.sort(completions, function(a, b) return a.score > b.score end)
    
    local max_results = options.n or 10
    if #completions > max_results then
      completions = vim.tbl_slice(completions, 1, max_results)
    end

    return completions
  end)
end

-- Create singleton instance
local vectorcode_async = M.new()

-- Initialize asynchronously
vectorcode_async:init():and_then(function(available)
  if available then
    vim.notify('VectorCode async client initialized', vim.log.levels.INFO)
  else
    vim.notify('VectorCode not available', vim.log.levels.WARN)
  end
end)

return vectorcode_async