---@class Operation
---@field name string
---@field promise Promise
---@field job table|nil
---@field metadata table
---@field state 'pending'|'running'|'completed'|'failed'|'cancelled'
---@field started_at integer|nil
---@field completed_at integer|nil
---@field job_id string|nil
---@field start fun(job: table?, metadata: table?): Operation
---@field complete fun(result: any): Operation
---@field fail fun(error: any): Operation
---@field cancel fun(reason?: string): Operation
---@field get_duration fun(): integer|nil
---@field on_complete fun(callback: fun(result: any)): Operation
---@field on_error fun(callback: fun(error: any)): Operation

---@class OperationManager
---@field start_operation fun(name: string, operation_fn: fun(operation: Operation)): Operation
---@field get_operation fun(name: string): Operation|nil
---@field cancel_operation fun(name: string, reason?: string)
---@field list_active_operations fun(): {name: string, operation: Operation}[]

local Promise = require('opencode.promise')
local job_registry = require('opencode.job_registry')

local M = {}
local Operation = {}
Operation.__index = Operation

---@param name string
---@return Operation
function M.new(name)
  return setmetatable({
    name = name,
    promise = Promise.new(),
    job = nil,
    metadata = {},
    state = 'pending',  -- pending | running | completed | failed | cancelled
    started_at = nil,
    completed_at = nil,
  }, Operation)
end

---@param job table|nil Job object
---@param metadata table|nil
---@return Operation
function Operation:start(job, metadata)
  self.job = job
  self.metadata = metadata or {}
  self.state = 'running'
  self.started_at = os.time()
  
  -- Register with job registry
  if job then
    self.job_id = job_registry.register(job, {
      operation = self.name,
      metadata = self.metadata,
    })
  end
  
  return self
end

---@param result any
---@return Operation
function Operation:complete(result)
  if self.state ~= 'running' then return end
  
  self.state = 'completed'
  self.completed_at = os.time()
  
  if self.job_id then
    job_registry.unregister(self.job_id)
  end
  
  self.promise:resolve(result)
  return self
end

---@param error any
---@return Operation
function Operation:fail(error)
  if self.state ~= 'running' then return end
  
  self.state = 'failed'
  self.completed_at = os.time()
  
  if self.job_id then
    job_registry.unregister(self.job_id)
  end
  
  self.promise:reject(error)
  return self
end

---@param reason string|nil
---@return Operation
function Operation:cancel(reason)
  if self.state ~= 'running' then return end
  
  self.state = 'cancelled'
  self.completed_at = os.time()
  
  if self.job and self.job.shutdown then
    self.job:shutdown()
  end
  
  if self.job_id then
    job_registry.unregister(self.job_id)
  end
  
  self.promise:cancel()
  return self
end

---@return integer|nil
function Operation:get_duration()
  if not self.started_at then return nil end
  local end_time = self.completed_at or os.time()
  return end_time - self.started_at
end

---@param callback fun(result: any)
---@return Operation
function Operation:on_complete(callback)
  self.promise:and_then(callback)
  return self
end

---@param callback fun(error: any)
---@return Operation
function Operation:on_error(callback)
  self.promise:catch(callback)
  return self
end

-- Global operation tracking
local active_operations = {}

---@param name string
---@param operation_fn fun(operation: Operation)
---@return Operation
function M.start_operation(name, operation_fn)
  local op = M.new(name)
  
  -- Run operation function with error handling
  local ok, result = pcall(operation_fn, op)
  
  if ok then
    active_operations[name] = op
    return op
  else
    op:fail(result)
    return op
  end
end

---@param name string
---@return Operation|nil
function M.get_operation(name)
  return active_operations[name]
end

---@param name string
---@param reason string|nil
function M.cancel_operation(name, reason)
  local op = active_operations[name]
  if op then
    op:cancel(reason or 'user_requested')
    active_operations[name] = nil
  end
end

---@return {name: string, operation: Operation}[]
function M.list_active_operations()
  local active = {}
  for name, op in pairs(active_operations) do
    if op.state == 'running' then
      table.insert(active, {name = name, operation = op})
    end
  end
  return active
end

return M