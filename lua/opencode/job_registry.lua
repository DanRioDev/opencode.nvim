---@class JobEntry
---@field id string
---@field job table Job object (should have is_running() and shutdown() methods)
---@field metadata table Optional metadata {operation: string, session_id: string, ...}
---@field created_at integer
---@field is_active fun(self: JobEntry): boolean

---@class JobRegistry
---@field register fun(job: table, metadata?: table): string
---@field unregister fun(job_id: string)
---@field get fun(job_id: string): JobEntry|nil
---@field list_active fun(): JobEntry[]
---@field shutdown fun(job_id: string): boolean
---@field shutdown_all fun(): integer
---@field setup_cleanup fun()

local M = {}

local active_jobs = {}
local job_counter = 0

---Register a job for tracking
---@param job table Job object (should have is_running() and shutdown() methods)
---@param metadata table Optional metadata {operation: string, session_id: string, ...}
---@return string job_id
function M.register(job, metadata)
  job_counter = job_counter + 1
  local job_id = 'job_' .. job_counter
  
  active_jobs[job_id] = {
    id = job_id,
    job = job,
    metadata = metadata or {},
    created_at = os.time(),
    is_active = function(self)
      return job and job.is_running and job:is_running()
    end,
  }
  
  return job_id
end

---Unregister a job
---@param job_id string
function M.unregister(job_id)
  active_jobs[job_id] = nil
end

---Get job by ID
---@param job_id string
---@return JobEntry|nil
function M.get(job_id)
  return active_jobs[job_id]
end

---List all active jobs
---@return JobEntry[] jobs
function M.list_active()
  local active = {}
  for job_id, entry in pairs(active_jobs) do
    if entry:is_active() then
      table.insert(active, entry)
    end
  end
  return active
end

---Shutdown specific job
---@param job_id string
---@return boolean success
function M.shutdown(job_id)
  local entry = active_jobs[job_id]
  if not entry then
    return false
  end
  
  if entry.job and entry.job.shutdown then
    entry.job:shutdown()
  end
  
  active_jobs[job_id] = nil
  return true
end

---Shutdown all active jobs
---@return integer count
function M.shutdown_all()
  local count = 0
  for job_id, entry in pairs(active_jobs) do
    if entry.job and entry.job.shutdown then
      entry.job:shutdown()
      count = count + 1
    end
  end
  active_jobs = {}
  return count
end

---Register cleanup on VimLeavePre
function M.setup_cleanup()
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('OpencodeJobCleanup', { clear = true }),
    callback = function()
      local count = M.shutdown_all()
      if count > 0 then
        vim.notify('Cleaned up ' .. count .. ' active jobs', vim.log.levels.DEBUG)
      end
    end,
  })
end

return M