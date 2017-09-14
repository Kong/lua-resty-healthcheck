local ERR = ngx.ERR
local INFO = ngx.INFO
local WARN = ngx.WARN
local DEBUG = ngx.DEBUG
local ngx_log = ngx.log
local new_timer = ngx.timer.at
local debug_mode = ngx.config.debug
local tostring = tostring
local ipairs = ipairs
local pcall = pcall
local cjson = require("cjson.safe").new()
local get_pid = ngx.worker.pid
local now = ngx.now
local sleep = ngx.sleep
local tinsert = table.insert
local tremove = table.remove
local utils = require("resty.healthcheck.utils")

-- constants
local LOG_PREFIX  = "[healthcheck] "


-- defaults
local DEFAULT_TIMEOUT = 2
local DEFAULT_INTERVAL = 1
local DEFAULT_WAIT_MAX = 0.5
local DEFAULT_WAIT_INTERVAL = 0.010



local _M = {}


--[[
Event handling

Where do we register callbacks? here, or in for example resty-worker-events
  - callback vs. publish-subscribe
  - ensure a callback runs only once vs. broadcast-style callbacks for all workers

on_local_status_change == on_status_change(false, ...)
on_status_change == on_status_change(true, ...)

  checker:on_local_status_change(is_broadcast, function(ip, port, status)
  	-- do something on the balancer
  end)

  checker:on_status_change(is_broadcast, function(ip, port, status)
  	-- do something on the balancer
  end)

event in a node
  -> on_status_change(false)
  -> on_status_change(true)

received event from another node
  -> on_status_change(true)

Timer management:
  - fully internal
  - 2 timers, one for healthy, one for unhealthy
  - using lock mechanism from upstream-healthcheck library to ensure independence
  - GC-able timers, or manual timer-stopping
--]]


local checker = {}
--============================================================================
-- Node management
--============================================================================

--- Add a target to the healthchecker.
-- @param ip ip-address of the target to check
-- @param port the port to check against, will be ignored when `ip` already
-- includes a port number
-- @param (optional) healthy a boolean value indicating the initial state
-- @return true on success, nil+err on failure
function checker:add_target(ip, port, healthy)
  
  -- TODO: implement
  
end
  
--- Remove a target from the healthchecker.
-- @param ip ip-address of the target being checked
-- @param port the port being checked against
-- @return true on success, nil+err on failure
function checker:remove_target(ip, port)
  
  -- TODO: implement
  
end

--============================================================================
-- Status management
--============================================================================

--- Gets the current status of the target
-- @param ip ip-address of the target being checked
-- @param port the port being checked against
-- @return `true` if healthy, `false` if unhealthy, or nil+error on failure
function checker:get_target_status(ip, port)
  
  -- TODO: implement
  
end

--- Sets the current status of the target.
-- This will immediately set the status, it will not count against
-- failure/success count.
-- @param ip ip-address of the target being checked
-- @param port the port being checked against
-- @return `true` on success, or nil+error on failure
function checker:set_target_status(ip, port, healthy)
  
  -- TODO: implement
  
end

--============================================================================
-- Health management
--============================================================================

--- Report a health failure.
-- Reports a health failure which will count against the number of occurences
-- required to make a target "fall" or "rise".
-- @param ip ip-address of the target being checked
-- @param port the port being checked against
-- @return `true` on success, or nil+error on failure
function checker:report_failure(ip, port)
  
  -- TODO: implement
  
end

--- Report a health success.
-- Reports a health success which will count against the number of occurences
-- required to make a target "fall" or "rise".
-- @param ip ip-address of the target being checked
-- @param port the port being checked against
-- @return `true` on success, or nil+error on failure
function checker:report_success(ip, port)
  
  -- TODO: implement
  
end

--- Report a http response code.
-- How the code is interpreted is based on the fall and rise strategies, if it
-- is in neither strategy, it will be ignored.
-- @param ip ip-address of the target being checked
-- @param port the port being checked against
-- @return `true` on success, or nil+error on failure
function checker:report_http_status(ip, port, req_status)
  
  -- TODO: implement
  
end

function checker:report_tcp_failure(ip, port)
  
  -- TODO: implement
  
end

-- TODO: method also for timeouts maybe?

--============================================================================
-- Timer callbacks
--============================================================================

-- Timer callback to check the status of currently HEALTHY targets
function checker.healthy_callback(premature, self)
  if premature or self.stop then
    self.timer_count = self.timer_count - 1
    return end
  end
    
  -- TODO: implement
  
  -- reschedule timer
  local ok, err = utils.gctimer(self.interval_healthy, self.healthy_callback, self)
  if not ok then
    self.timer_count = self.timer_count - 1
    self:log(ERR, "failed to re-create 'healthy' timer: ", err)
    return
  end
end

-- Timer callback to check the status of currently UNHEALTHY targets
function checker.unhealthy_callback(premature, self)
  if premature or self.stop then
    self.timer_count = self.timer_count - 1
    return end
  end
    
  -- TODO: implement
  
  -- reschedule timer
  local ok, err = utils.gctimer(self.interval_healthy, self.healthy_callback, self)
  if not ok then
    self.timer_count = self.timer_count - 1
    self:log(ERR, "failed to re-create 'unhealthy' timer: ", err)
    return
  end
end

--============================================================================
-- Miscellaneous
--============================================================================

-- Log a message specific to this checker
-- @param level standard ngx log level constant
function checker:log(level, ...)
  ngx_log(level, LOG_PREFIX, "(", self.name, ") " ...)
end

--- Stop the background health checks.
-- @return true
function checker:stop()
  self.stop = true
  return true
end

--- Starts the background health checks.
-- @return true or nil+error
function checker:start()
  if not self.timer_count = 0 then
    return nil, "cannot start, " .. self.timer_count .. " (of 2) timers are still running"
  end
  
  local ok, err
  ok, err = ngx.timer.at(0, self.healthy_callback, self)
  if not ok then
    return nil, "failed to create 'healthy' timer: " .. err
  end
  self.timer_count = self.timer_count + 1

  ok, err = ngx.timer.at(0, self.unhealthy_callback, self)
  if not ok then
    return nil, "failed to create 'unhealthy' timer: " .. err
  end
  self.timer_count = self.timer_count + 1

  self.stop = false  -- do this at the end, so if either creation fails, the other stops also
  return true
end

--============================================================================
-- Create health-checkers
--============================================================================

--[[
  {
      name = "some unique name"                           -- needed as key in shm
      shm = "healthcheck"   																			-- hidden in worker-events??
      type = "http"                                               -- http, https, tcp
      http_req = "GET /status HTTP/1.0\r\nHost: foo.com\r\n\r\n"  -- raw request?
      interval_healthy = 2000,                                    -- run the check cycle every 2 sec on healthy nodes 
      interval_unhealthy = 500											        			-- on unhealthy nodes
      timeout = 1000,                                             -- 1 sec is the timeout for network operations
      fall_strategy = {
         occurences = 4,                                          -- successive failures before turning a peer down
         statuses = {429},                                        -- a list valid HTTP status code to make it fail
         
      }
      rise_strategy = {
         occurences = 4,                                          -- successive failures before turning a peer down
         statuses = {200, 302},                                   -- a list valid HTTP status code to make it fail
         
      }
      concurrency = 10,  -- concurrency level for test requests
  })
--]]

--- Creates a new health-checker instance.
-- @param opts table with checker options
-- @return checker object
local function new(opts)
  local obj = {}
  
  -- TODO: implement
  
  -- decorate with methods
  for k,v in pairs(checker) do
    obj[k] = v
  end
  
  -- start timers
  obj.stop = true      -- flag to instruct timers to exit
  obj.timer_count = 0  -- number of timers running
  obj:start()
  
  return obj
end


return _M
