---@class IdleDetector
---@field private _last_activity number Timestamp of last user activity in milliseconds
---@field private _timer uv_timer_t|nil Polling timer
---@field private _callback function|nil Callback to invoke when idle threshold exceeded
---@field private _threshold number Idle threshold in milliseconds
---@field private _check_interval number How often to check for idle state in milliseconds
---@field private _is_idle boolean Current idle state
---@field private _autocmd_group number|nil Autocmd group ID
---@field private _started boolean Whether idle detector is currently running
local IdleDetector = {}
IdleDetector.__index = IdleDetector

---Creates a new idle detector instance
---@param opts {threshold: number, callback: function, check_interval?: number}
---@return IdleDetector
function IdleDetector.new(opts)
  if not opts or not opts.threshold or not opts.callback then
    error('IdleDetector.new requires {threshold: number, callback: function}')
  end

  local self = setmetatable({}, IdleDetector)
  self._threshold = opts.threshold
  self._callback = opts.callback
  self._check_interval = opts.check_interval or 1000 -- Default 1 second polling
  self._last_activity = vim.loop.now()
  self._is_idle = false
  self._timer = nil
  self._autocmd_group = nil
  self._started = false
  return self
end

---Marks that user activity occurred
---@private
function IdleDetector:_record_activity()
  self._last_activity = vim.loop.now()
  if self._is_idle then
    self._is_idle = false
  end
end

---Checks if idle threshold has been exceeded
---@private
function IdleDetector:_check_idle()
  local now = vim.loop.now()
  local elapsed = now - self._last_activity

  if not self._is_idle and elapsed >= self._threshold then
    self._is_idle = true
    if self._callback then
      -- Schedule callback to run in main event loop
      vim.schedule(function()
        self._callback()
      end)
    end
  end
end

---Starts the idle detection
function IdleDetector:start()
  if self._started then
    return -- Already started
  end

  self._started = true

  -- Create autocmd group for activity tracking
  self._autocmd_group = vim.api.nvim_create_augroup('OpenCodeIdleDetector', { clear = true })

  -- Track all relevant user activity events
  local activity_events = {
    'CursorMoved',
    'CursorMovedI',
    'InsertEnter',
    'InsertLeave',
    'TextChanged',
    'TextChangedI',
    'CmdlineEnter',
    'WinEnter',
    'BufEnter',
  }

  for _, event in ipairs(activity_events) do
    vim.api.nvim_create_autocmd(event, {
      group = self._autocmd_group,
      callback = function()
        self:_record_activity()
      end,
    })
  end

  -- Ensure cleanup on Neovim exit to prevent hanging
  vim.api.nvim_create_autocmd({ 'VimLeavePre', 'QuitPre' }, {
    group = self._autocmd_group,
    once = true,
    callback = function()
      self:stop()
    end,
  })

  -- Create polling timer to check for idle state
  local loop = vim.loop
  if not loop then
    vim.notify('Failed to initialize idle detector: vim.loop unavailable', vim.log.levels.ERROR)
    self._started = false
    return
  end

  self._timer = loop.new_timer()
  if not self._timer then
    vim.notify('Failed to create idle detection timer', vim.log.levels.ERROR)
    self._started = false
    return
  end

  local ok, err = pcall(function()
    self._timer:start(
      self._check_interval, -- Initial delay
      self._check_interval, -- Repeat interval
      vim.schedule_wrap(function()
        self:_check_idle()
      end)
    )
  end)

  if not ok then
    vim.notify('Failed to start idle detection timer: ' .. vim.inspect(err), vim.log.levels.ERROR)
    if self._timer then
      self._timer:close()
      self._timer = nil
    end
    self._started = false
  end
end

---Stops the idle detection
function IdleDetector:stop()
  if not self._started then
    return
  end

  self._started = false

  if self._timer then
    local ok, err = pcall(function()
      self._timer:stop()
      self._timer:close()
    end)
    if not ok then
      vim.notify('Error stopping idle detector timer: ' .. vim.inspect(err), vim.log.levels.WARN)
    end
    self._timer = nil
  end

  if self._autocmd_group then
    local ok, err = pcall(function()
      vim.api.nvim_del_augroup_by_id(self._autocmd_group)
    end)
    if not ok then
      vim.notify('Error cleaning up idle detector autocommands: ' .. vim.inspect(err), vim.log.levels.WARN)
    end
    self._autocmd_group = nil
  end

  self._is_idle = false
end

---Updates the idle threshold
---@param threshold number New threshold in milliseconds
function IdleDetector:set_threshold(threshold)
  if type(threshold) ~= 'number' or threshold <= 0 then
    error('Threshold must be a positive number')
  end
  self._threshold = threshold
end

---Updates the callback function
---@param callback function New callback function
function IdleDetector:set_callback(callback)
  if type(callback) ~= 'function' then
    error('Callback must be a function')
  end
  self._callback = callback
end

---Returns current idle state
---@return boolean
function IdleDetector:is_idle()
  return self._is_idle
end

---Returns time since last activity in milliseconds
---@return number
function IdleDetector:time_since_activity()
  return vim.loop.now() - self._last_activity
end

return IdleDetector
