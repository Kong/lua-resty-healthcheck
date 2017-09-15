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
local table_insert = table.insert
local table_remove = table.remove
local utils = require("resty.healthcheck.utils")
local resty_lock = require ("resty.lock")
local re_find = ngx.re.find

-- constants
local LOG_PREFIX = "[healthcheck] "
local SHM_PREFIX = "lua-resty-healthcheck:"
local EMPTY = setmetatable({},{
    __newindex = function()
      error("the EMPTY table is read only, check your code!", 2)
    end
  })

-- defaults
local DEFAULT_TIMEOUT = 2
local DEFAULT_INTERVAL = 1
local DEFAULT_WAIT_MAX = 0.5
local DEFAULT_WAIT_INTERVAL = 0.010

local EVENTS = setmetatable({
  --"add",        -- no 'add' because adding will result in `(un)healthy` events
  "remove",
  "healthy",
  "unhealthy",
},{
  __index = function(self, key)
    error(("'%s' is not a valid event name"):format(tostring(key)))
  end
})



local _M = {}


--[[

* Each worker will instance of the checker
* They will two timer loops, `healthy_callback` and `unhealthy_callback`
  * typically, unhealthy runs faster than healthy
    (especially on passive checks: healthy comes from normal traffic, unhealthy needs checks to get upstream back to healthy status)
* When a status changes, we want workers to be notified as soon as possible
  * We don't want to rely on the two `healthy_callback` and `unhealthy_callback` above for that
  * A worker will determine that a status has changed
    * Health management functions (report_*) will determine a status change based on fall and rise strategies, and post an event via worker-events
      * Those functions can be called by the periodic callbacks, or directly (in the case of passive checks)
      * Those functions are the only ones that lock and update the occurence counters
* Provide a convenience method to register a callback that listens on the worker-events status change event
	* This keeps the worker-events dependency internal to the healthcheck library

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
  - GC-able timers, or manual timer-stopping ==> to be tested! overall GC,
    because the event library may also hold on to the healthchecker objects


SHM storage
 - data types:
    - list of targets + healthcheck 'execution' data
    - individual health data per target
 - for now serialize as json in shm

--]]



-- Non-performing serialization for now...
-- serialize a table to a string
local function serialize(t)
  return cjson.encode(t)
end

-- deserialize a string to a table
local function deserialize(s)
  return cjson.decode(s)
end



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
  ip   = tostring(assert(ip, "no ip address provided"))
  port = tostring(assert(ip, "no port number provided"))
  healthy = not not healthy   -- force to boolean

  local lock, err, ok, err2, target_list
  
  lock, err = resty_lock.new(self.shm, {
                exptime = 10,  -- timeout after which lock is released anyway
                timeout = 5,   -- max wait time to acquire lock
              })
  if not lock then return nil, "failed to create lock:" .. err end
  
  ok, err = lock:lock(self.TARGET_LIST_LOCK_KEY)
  if not ok then return nil, "failed to acquire lock: " .. err end
  
  target_list, err = self.shm.get(self.TARGET_LIST_KEY)
  if err then
    err = "failed to fetch target_list from shm: " .. err

  else
    if target_list then
      target_list = deserialize(target_list)
    else
      target_list = {}
    end

    -- check whether we already have this target
    for _, target in ipairs(target_list) do
      if target.ip == ip and target.port == port then
        err = ("target '%s:%s' already exists"):format(ip, port)
        break
      end
    end

    if not err then
      -- target does not exist, go add it
      target_list[#target_list + 1] = {
        ip = ip,
        port = port,
      }
      target_list = serialize(target_list)

      -- we first add the health status, and only then the updated list
      -- this prevents race conditions when a healthcheker get the initial
      -- state from the shm
      ok, err2 = self.shm.set(self.TARGET_STATUS:format(ip, port), healthy)
      if not ok then
        -- err2: not failing this routine, just log the error and continue
        self.log(ERR, "failed to set initial health status in shm: ", err2)
      end

      ok, err = self.shm.set(self.TARGET_LIST_KEY, target_list)
      if not ok then
        err = "failed to store target_list in shm: " .. err
      end

      if not err then
        -- raise event for our newly added target
        if healthy then
          self.raise_event(self.events.healthy, ip, port)
        else
          self.raise_event(self.events.unhealthy, ip, port)
        end
      end
    end
  end
  
  ok, err2 = lock:unlock()
  if not ok then 
    -- err2: not failing this routine, just log the error and continue
    self.log(ERR, "failed to release lock '", self.TARGET_LIST_LOCK_KEY,
                  "': ", err2)
  end

  return err and nil, err
end


--- Remove a target from the healthchecker.
-- The target not existing is not considered an error.
-- @param ip ip-address of the target being checked
-- @param port the port being checked against
-- @return true on success, nil+err on failure
function checker:remove_target(ip, port)
  ip   = tostring(assert(ip, "no ip address provided"))
  port = tostring(assert(ip, "no port number provided"))

  local lock, err, ok, err2, target_list
  
  lock, err = resty_lock.new(self.shm, {
                exptime = 10,  -- timeout after which lock is released anyway
                timeout = 5,   -- max wait time to acquire lock
              })
  if not lock then return nil, "failed to create lock:" .. err end
  
  ok, err = lock:lock(self.TARGET_LIST_LOCK_KEY)
  if not ok then return nil, "failed to acquire lock: " .. err end
  
  target_list, err = self.shm.get(self.TARGET_LIST_KEY)
  if err then
    err = "failed to fetch target_list from shm: " .. err

  else
    if target_list then
      target_list = deserialize(target_list)
    else
      target_list = {}
    end

    -- find the target
    local target_found
    for i, target in ipairs(target_list) do
      if target.ip == ip and target.port == port then
        target_found = target
        table_remove(target_list, i)
        break
      end
    end

    if target_found then
      -- go update the shm
      target_list = serialize(target_list)

      -- we first write the updated list, and only then remove the health 
      -- status this prevents race conditions when a healthcheker get the
      -- initial state from the shm
      ok, err = self.shm.set(self.TARGET_LIST_KEY, target_list)
      if not ok then
        err = "failed to store target_list in shm: " .. err
      end

      if not err then
        -- remove health status from shm
        ok, err2 = self.shm.set(self.TARGET_STATUS:format(ip, port), nil)
        if not ok then
          -- err2: not failing this routine, just log the error and continue
          self.log(ERR, "failed to remove health status from shm: ", err2)
        end

        -- raise event for our removed target
        self.raise_event(self.events.remove, ip, port)
      end
    end
  end
  
  ok, err2 = lock:unlock()
  if not ok then 
    -- err2: not failing this routine, just log the error and continue
    self.log(ERR, "failed to release lock '", self.TARGET_LIST_LOCK_KEY,
                  "': ", err2)
  end

  return err and nil, err
end



--============================================================================
-- Status management
--============================================================================

--[[ (not for the first iteration)
--- Gets the current status of the target
-- @param ip ip-address of the target being checked
-- @param port the port being checked against
-- @return `true` if healthy, `false` if unhealthy, or nil+error on failure
function checker:get_target_status(ip, port)
  
  -- TODO: implement
  -- needs to lock the same data that report_* functions lock
  -- alternative is to keep a cache and return potentially outdated data
  
end
]]

--[[ (not for the first iteration)
--- Sets the current status of the target.
-- This will immediately set the status, it will not count against
-- failure/success count.
-- @param ip ip-address of the target being checked
-- @param port the port being checked against
-- @return `true` on success, or nil+error on failure
function checker:set_target_status(ip, port, enabled)
  -- What is this function setting? it should not set the status but the "status-info"
  -- that defines wheter it is up/down.
  -- Eg. 100 successes in a row, then we call this to set it down anyway.
  -- The next healthcheck is a success. Now what is going to happen?

  -- OPTION: if status is set to `false` then it is marked `down` and
  -- excluded from the healthchecks (or any other health info from the
  -- health management functions). If status is set to `true` it will be checked
  -- and health info will be collected
  
  -- OPTION: Will mark a node as down, and keep it down, indepedent of received health data.
  -- When the change to down is a change in status, an event will be sent.
  -- While down healthchecks will continue, but not influence the state.
  -- When reenabling the checks, the last state, according to the last health data
  -- receieved (during the time the node was forcefully down) will detrmine the new status

  -- OPTION: if status is set to `false` then it is marked `disabled` and
  -- healthchecks keep going but do not report events. If status is set to `true`
  -- it will start reporting status changes again. Also reports a `enabled`/`disabled` event.
 

  -- TODO: implement
  
end
]]



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
-- @param req_status the http statuscode, or nil to report an invalid http response
-- @return `true` on success, or nil+error on failure
function checker:report_http_status(ip, port, req_status)
  
  -- TODO: implement
  
end


-- TODO check what kind of information we get from the OpenResty layer
-- in order to tell these error conditions apart
-- https://github.com/openresty/lua-resty-core/blob/master/lib/ngx/balancer.md#get_last_failure
function checker:report_tcp_failure(ip, port)
  
  -- TODO: implement
  
end


function checker:report_timeout(ip, port)
  
  -- TODO: implement
  
end



--============================================================================
-- Healthcheck runner
--============================================================================

-- Runs a single healthcheck probe
function checker:run_single_check(ip, port, healthy)
  
  local sock, err = ngx.socket.tcp()
  if not sock then
    self:log(ERR, "failed to create stream socket: ", err)
    return
  end

  sock:settimeout(self.timeout)

  local ok
  ok, err = sock:connect(ip, port)
  if not ok then
    if not healthy then
      self:log(ERR, "failed to connect to '", ip, ":", port, "': ", err)
    end
    if err == "timeout" then
      sock:close()  -- timeout errors do not close the socket.
      return self:report_timeout(ip, port)
    end
    return self:report_tcp_failure(ip, port)
  end
  
  if self.type == "tcp" then
    return self:report_tcp_success()  --TODO: does not exist yet
  end

  -- TODO: implement https

  local bytes
  bytes, err = sock:send(self.http_request)
  if not bytes then
    self:log(ERR, "failed to send http request to '", ip, ":", port, "': ", err)
    if err == "timeout" then
      sock:close()  -- timeout errors do not close the socket.
      return self:report_timeout(ip, port)
    end
    return self:report_tcp_failure(ip, port)
  end

  local status_line
  status_line, err = sock:receive()
  if not status_line then
    self:log(ERR, "failed to receive status line from '", ip, ":", port, "': ", err)
    if err == "timeout" then
      sock:close()  -- timeout errors do not close the socket.
      return self:report_timeout(ip, port)
    end
    return self:report_tcp_failure(ip, port)
  end

  local from, to = re_find(status_line,
                          [[^HTTP/\d+\.\d+\s+(\d+)]],
                          "joi", nil, 1)
  local status
  if from then
    status = tonumber(status_line:sub(from, to))
  else
    self:log(ERR, "bad status line from  '", ip, ":", port, "': ", status_line)
    -- note: 'status' will be reported as 'nil'
  end

  sock:close()

  return self:report_http_status(ip, port, status)
end

-- executes a work package (a list of checks) sequentially
function checker:run_work_package(work_package)
  for _, target in ipairs(work_package) do
    self:run_single_check(target.ip, target.port)
  end
end

-- runs the active healthchecks concurrently, in multiple work packages.
-- @param list the list of targets to check
function checker:active_check_targets(list)
  local idx = 1
  local work_packages = {}
  for _, target in ipairs(list) do
    local package = work_packages[idx]
    if not package then
      package = {}
      work_packages[idx] = package
    end
    package[#package + 1] = target
    idx = idx + 1
    if idx > self.concurrency then idx = 1 end
  end
  
  -- hand out work-packages to the threads, note the "-1" because this timer
  -- thread will handle the last package itself.
  for i = 1, #work_packages - 1 do
    work_packages[i].thread = ngx.thread.spawn(self.run_work_package, self, work_packages[i])
  end
  -- run last package myself
  self:run_work_package(work_packages[#work_packages])
  
  -- wait for everybody to finish
  for i = 1, #work_packages - 1 do
    ngx.thread.wait(work_packages[i])
  end
end

--============================================================================
-- Callbacks, timers and events
--============================================================================
-- The timer callbacks are responsible for checking the status, upon success/
-- failure they will call the health-management functions to deal with the
-- results of the checks.

-- Timer callback to check the status of currently HEALTHY targets
function checker.healthy_callback(premature, self)
  if premature or self.stop then
    self.timer_count = self.timer_count - 1
    return
  end

  -- create a list of targets to check, here we can still do this atomically
  local list_to_check = {}
  for _, target in ipairs(self.targets) do
    if target.healthy then  -- only healthy ones
      list_to_check[#list_to_check + 1] = {
            ip = target.ip,
            port = target.port,
            healthy = target.healthy,
      }
    end
  end
  
  if not list_to_check[1] then
    self:log(DEBUG, "checking healthy targets: nothing to do")
  else
    self:log(DEBUG, "checking healthy targets: #", #list_to_check)
    self:active_check_targets(list_to_check)
  end

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
    return
  end

  -- create a list of targets to check, here we can still do this atomically
  local list_to_check = {}
  for _, target in ipairs(self.targets) do
    if not target.healthy then  --- only unhealthy ones
      list_to_check[#list_to_check + 1] = { ip = target.ip, port = target.port }
    end
  end
  
  if not list_to_check[1] then
    self:log(DEBUG, "checking unhealthy targets: nothing to do")
  else
    self:log(DEBUG, "checking unhealthy targets: #", #list_to_check)
    self:active_check_targets(list_to_check)
  end

  -- reschedule timer
  local ok, err = utils.gctimer(self.interval_healthy, self.healthy_callback, self)
  if not ok then
    self.timer_count = self.timer_count - 1
    self:log(ERR, "failed to re-create 'unhealthy' timer: ", err)
    return
  end
end


-- Event handler callback
function checker:event_handler(event_name, ip, port)

  local target_found = (self.targets[ip] or EMPTY)[port]
  
  if event_name == self.events.remove then
    if target_found then
      -- remove hash part
      self.targets[target_found.ip][target_found.port] = nil
      if not next(self.targets[target_found.ip]) then
        -- no more ports on this ip, so delete it
        self.targets[target_found.ip] = nil
      end
      -- remove from list part
      for i, target in ipairs(self.targets) do
        if target.ip == ip and target.port == port then
          table_remove(self.targets, i)
          break
        end
      end
      self:log(DEBUG, "event received: target '", ip, ":", port, "' removed")

    else
      self:log(WARN, "event received to remove an unknown target '", ip, ":", port)
    end

  elseif event_name == self.events.healthy or 
         event_name == self.events.unhealthy then
    if not target_found then
      -- it is a new target, must add it first
      local target_found = { ip = ip, port = port }
      self.targets[target_found.ip] = self.targets[target_found.ip] or {}
      self.targets[target_found.ip][target_found.port] = target_found
      self.targets[#self.targets + 1] = target_found
      self:log(DEBUG, "event received: target added ", ip, ":", port)
    end
    local health = (event_name == self.events.healthy)
    self:log(DEBUG, "event received target status '", ip, ":", port,
                    "' from '", target_found.healthy, "' to '", health, "'")
    target_found.healthy = health

  else
    self:log(WARN, "unknown event received: ", event_name)
  end
end


--============================================================================
-- Miscellaneous
--============================================================================

-- Log a message specific to this checker
-- @param level standard ngx log level constant
function checker:log(level, ...)
  ngx_log(level, LOG_PREFIX, "(", self.name, ") ", ...)
end


-- Raises an event for a target status change.
function checker:raise_event(event_name, ip, port)

  -- TODO implement, depends on event lib

end


--- Stop the background health checks.
-- @return true
function checker:stop()
  self.stop = true
  --TODO: unregister event handler, to be eligible for GC
  return true
end


--- Starts the background health checks.
-- @return true or nil+error
function checker:start()
  if not self.timer_count == 0 then
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

  --TODO: unregister and re-register event handler

  self.stop = false  -- do this at the end, so if either creation fails, the other stops also
  return true
end



--============================================================================
-- Create health-checkers
--============================================================================

--[[
  {
      name = "some unique name"                                   -- needed as key in shm
      shm_name = "healthcheck"   																  -- hidden in worker-events??
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
-- @return checker object, or nil + error
function _M.new(opts)
  local err
  local self = {
    -- options defaults
    concurrency = 10,    -- how many concurrent requests while probing
    timeout = 1000,      -- network timeout for probes
    http_request = nil,  -- raw http request to send
    -- other properties
    targets = nil,   -- list of targets, initially loaded, maintained by events
    events = nil,    -- hash table with supported events (prevent magic strings)
    stop = true,     -- flag to idicate to timers to stop checking
    timer_count = 0, -- number of running timers
    shm = nil,       -- the shm to use (actual shm, not its name)
  }
  
  assert(opts.shm_name, "required option 'shm_name' is missing")
  self.shm = ngx.shared[tostring(opts.shm_name)]
  assert(self.shm, ("no shm found by name '%s'"):format(opts.shm_name))
  
  -- TODO: implement
  
  -- decorate with methods and constants
  self.events = EVENTS
  for k,v in pairs(checker) do
    self[k] = v
  end
  
  -- prepare shm keys
  self.TARGET_STATUS        = SHM_PREFIX .. self.name .. ":%s:%s:status"
  self.TARGET_LIST_KEY      = SHM_PREFIX .. self.name .. ":target_list"
  self.TARGET_LIST_LOCK_KEY = SHM_PREFIX .. self.name .. ":target_list_lock"
  
  -- register for events, and directly after load initial target list
  -- order is important!
  -- TODO: implementation depends on the actual event library used
  event_lib.register(
    function(...)
      -- just a wrapper to be able to access `self` as a closure
      return self:event_handler(event_name, ip, port)
    end
  )
  -- Now load the initial list of targets
  do
    -- all atomic accesses, so we do not need a lock
    self.targets, err = self.shm.get(self.TARGET_LIST_KEY)
    if err then
      return nil, "failed to fetch target_list from shm: " .. err
    end
    if self.targets then
      self.targets = deserialize(self.targets)
    else
      self.targets = {}
    end
    -- load individual statusses
    for _, target in ipairs(self.targets) do
      target.healthy = self.shm.get(self.TARGET_STATUS:format(target.ip, target.port))
      -- fill-in the hash part for easy lookup
      self.targets[target.ip] = self.targets[target.ip] or {}
      self.targets[target.ip][target.port] = target
    end
  end

  -- start timers
  ok, err = self:start()
  if not ok then
    --TODO: unregister event handler, to be eligible for GC
    return nil, err
  end
  
  return self
end


return _M
