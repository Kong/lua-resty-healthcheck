--------------------------------------------------------------------------
-- Healthcheck library for OpenResty.
--
-- Some notes on the usage of this library:
--
-- - Each target will have 4 counters, 1 success counter and 3 failure
-- counters ('http', 'tcp', and 'timeout'). Any failure will _only_ reset the
-- success counter, but a success will reset _all three_ failure counters.
--
-- - All targets are uniquely identified by their IP address and port number
-- combination, most functions take those as arguments.
--
-- - All keys in the SHM will be namespaced by the healthchecker name as
-- provided to the `new` function. Hence no collissions will occur on shm-keys
-- as long as the `name` is unique.
--
-- - Active healthchecks will be synchronized across workers, such that only
-- a single active healthcheck runs.
--
-- - Events will be raised in every worker, see [lua-resty-worker-events](https://github.com/Kong/lua-resty-worker-events)
-- for details.
--
-- @copyright 2017 Kong Inc.
-- @author Hisham Muhammad, Thijs Schreijer
-- @license Apache 2.0

local ERR = ngx.ERR
local WARN = ngx.WARN
local DEBUG = ngx.DEBUG
local ngx_log = ngx.log
local tostring = tostring
local ipairs = ipairs
local cjson = require("cjson.safe").new()
local table_remove = table.remove
local utils = require("resty.healthcheck.utils")
local worker_events = require("resty.worker.events")
local resty_lock = require ("resty.lock")
local re_find = ngx.re.find
local bit = require("bit")
local ngx_now = ngx.now

-- constants
local EVENT_SOURCE_PREFIX = "lua-resty-healthcheck"
local LOG_PREFIX = "[healthcheck] "
local SHM_PREFIX = "lua-resty-healthcheck:"
local EMPTY = setmetatable({},{
    __newindex = function()
      error("the EMPTY table is read only, check your code!", 2)
    end
  })


-- Counters: a 32-bit shm integer can hold up to four 8-bit counters.
-- Here, we are using three.
local CTR_HTTP    = 0x000000
local CTR_TCP     = 0x000100
local CTR_TIMEOUT = 0x010000
local CTR_SUCCESS = CTR_HTTP   -- same, but stored in separate shm value

local CTR_NAME_FAILURE = {
  [CTR_HTTP]    = "HTTP",
  [CTR_TCP]     = "TCP",
  [CTR_TIMEOUT] = "TIMEOUT",
}

local CTR_NAME_SUCCESS = {
  [CTR_SUCCESS] = "SUCCESS"
}


--- The list of potential events generated.
-- The `checker.EVENT_SOURCE` field can be used to subscribe to the events, see the
-- example below. Each of the events will get a table passed containing
-- the target details `ip`, `port`, and `hostname`.
-- See [lua-resty-worker-events](https://github.com/Kong/lua-resty-worker-events).
-- @field remove Event raised when a target is removed from the checker.
-- @field healthy This event is raised when the target status changed to
-- healthy (and when a target is added as `healthy`).
-- @field unhealthy This event is raised when the target status changed to
-- unhealthy (and when a target is added as `unhealthy`).
-- @table checker.events
-- @usage -- Register for all events from `my_checker`
-- local event_callback = function(target, event, source, source_PID)
--   local t = target.ip .. ":" .. target.port .." by name '" ..
--             target.hostname .. "' ")
--
--   if event == my_checker.events.remove then
--     print(t .. "has been removed")
--
--   elseif event == my_checker.events.healthy then
--     print(t .. "is now healthy")
--
--   elseif event == my_checker.events.unhealthy then
--     print(t .. "is now unhealthy")
--
--   else
--     print("received an unknown event: " .. event)
--   end
-- end
--
-- worker_events.register(event_callback, my_checker.EVENT_SOURCE)
local EVENTS = setmetatable({}, {
  __index = function(self, key)
    error(("'%s' is not a valid event name"):format(tostring(key)))
  end
})
for _, event in ipairs({
  "remove",
  "healthy",
  "unhealthy",
  "clear",
}) do
  EVENTS[event] = event
end


-- Some color for demo purposes
local use_color = false
local id = function(x) return x end
local green        = use_color and function(str) return ("\027[32m" .. str .. "\027[0m") end or id
local red          = use_color and function(str) return ("\027[31m" .. str .. "\027[0m") end or id
local worker_color = use_color and function(str) return ("\027["..tostring(31 + ngx.worker.pid() % 5).."m"..str.."\027[0m") end or id

-- Debug function
local function dump(...) print(require("pl.pretty").write({...})) end

local _M = {}


-- TODO: improve serialization speed
-- serialize a table to a string
local function serialize(t)
  return cjson.encode(t)
end


-- deserialize a string to a table
local function deserialize(s)
  return cjson.decode(s)
end


local function get_shm_key(key_prefix, ip, port)
  return key_prefix .. ":" .. ip .. ":" .. port
end


local checker = {}


------------------------------------------------------------------------------
-- Node management.
-- @section node-management
------------------------------------------------------------------------------


-- @return the target list from the shm, an empty table if not found, or
-- `nil + error` upon a failure
local function fetch_target_list(self)
  local target_list, err = self.shm:get(self.TARGET_LIST)
  if err then
    return nil, "failed to fetch target_list from shm: " .. err
  end

  return target_list and deserialize(target_list) or {}
end


--- Run the given function holding a lock on the target list.
-- WARNING: the callback will run unprotected, so it should never
-- throw an error, but always return `nil + error` instead.
-- @param self The checker object
-- @param fn The function to execute
-- @return The results of the function; or nil and an error message
-- in case it fails locking.
local function locking_target_list(self, fn)

  local lock, lock_err = resty_lock:new(self.shm_name, {
                  exptime = 10,  -- timeout after which lock is released anyway
                  timeout = 5,   -- max wait time to acquire lock
                })
  if not lock then
    return nil, "failed to create lock:" .. lock_err
  end

  local ok, err = lock:lock(self.TARGET_LIST_LOCK)
  if not ok then
    return nil, "failed to acquire lock: " .. err
  end

  local target_list
  target_list, err = fetch_target_list(self)

  local final_ok, final_err

  if target_list then
    final_ok, final_err = fn(target_list)
  else
    final_ok, final_err = nil, err
  end

  ok, err = lock:unlock()
  if not ok then
    -- recoverable: not returning this error, only logging it
    self:log(ERR, "failed to release lock '", self.TARGET_LIST_LOCK,
                  "': ", err)
  end

  return final_ok, final_err
end


--- Add a target to the healthchecker.
-- When the ip + port combination already exists, it will simply return success
-- (without updating either `hostname` nor `healthy` status).
-- @param ip IP address of the target to check.
-- @param port the port to check against.
-- @param hostname (optional) hostname to set as the host header in the the
-- HTTP probe request (defaults to the provided IP address).
-- @param healthy (optional) a boolean value indicating the initial state,
-- default is `true`.
-- @return `true` on success, or `nil + error` on failure.
function checker:add_target(ip, port, hostname, healthy)
  ip = tostring(assert(ip, "no ip address provided"))
  port = assert(tonumber(port), "no port number provided")
  hostname = hostname or ip
  if healthy == nil then
    healthy = true
  end

  local ok, err = locking_target_list(self, function(target_list)

    -- check whether we already have this target
    for _, target in ipairs(target_list) do
      if target.ip == ip and target.port == port then
        self:log(DEBUG, "adding an existing target: ", ip, ":", port, " (ignoring)")
        return false
      end
    end

    -- we first add the health status, and only then the updated list.
    -- this prevents a state where a target is in the list, but does not
    -- have a key in the shm.
    local ok, err = self.shm:set(get_shm_key(self.TARGET_STATUS, ip, port), healthy)
    if not ok then
      self:log(ERR, "failed to set initial health status in shm: ", err)
    end

    -- target does not exist, go add it
    target_list[#target_list + 1] = {
      ip = ip,
      port = port,
      hostname = hostname,
    }
    target_list = serialize(target_list)

    ok, err = self.shm:set(self.TARGET_LIST, target_list)
    if not ok then
      return nil, "failed to store target_list in shm: " .. err
    end

    -- raise event for our newly added target
    local event = healthy and "healthy" or "unhealthy"
    self:raise_event(self.events[event], ip, port, hostname)

    return true
  end)

  if ok == false then
    -- the target already existed, no event, but still success
    return true
  end

  return ok, err

end


-- Remove health status entries from an individual target from shm
-- @param self The checker object
-- @param ip IP address of the target being checked.
-- @param port the port being checked against.
local function clear_target_data_from_shm(self, ip, port)
    local ok, err = self.shm:set(get_shm_key(self.TARGET_STATUS, ip, port), nil)
    if not ok then
      self:log(ERR, "failed to remove health status from shm: ", err)
    end
    ok, err = self.shm:set(get_shm_key(self.TARGET_OKS, ip, port), nil)
    if not ok then
      self:log(ERR, "failed to clear health counter from shm: ", err)
    end
    ok, err = self.shm:set(get_shm_key(self.TARGET_NOKS, ip, port), nil)
    if not ok then
      self:log(ERR, "failed to clear health counter from shm: ", err)
    end
end


--- Remove a target from the healthchecker.
-- The target not existing is not considered an error.
-- @param ip IP address of the target being checked.
-- @param port the port being checked against.
-- @return `true` on success, or `nil + error` on failure.
function checker:remove_target(ip, port)
  ip   = tostring(assert(ip, "no ip address provided"))
  port = assert(tonumber(port), "no port number provided")

  return locking_target_list(self, function(target_list)

    -- find the target
    local target_found
    for i, target in ipairs(target_list) do
      if target.ip == ip and target.port == port then
        target_found = target
        table_remove(target_list, i)
        break
      end
    end

    if not target_found then
      return true
    end

    -- go update the shm
    target_list = serialize(target_list)

    -- we first write the updated list, and only then remove the health
    -- status this prevents race conditions when a healthchecker gets the
    -- initial state from the shm
    local ok, err = self.shm:set(self.TARGET_LIST, target_list)
    if not ok then
      return nil, "failed to store target_list in shm: " .. err
    end

    clear_target_data_from_shm(self, ip, port)

    -- raise event for our removed target
    self:raise_event(self.events.remove, ip, port, target_found.hostname)

    return true
  end)
end


--- Clear all healthcheck data.
-- @return `true` on success, or `nil + error` on failure.
function checker:clear()

  return locking_target_list(self, function(target_list)

    local old_target_list = target_list

    -- go update the shm
    target_list = serialize({})

    local ok, err = self.shm:set(self.TARGET_LIST, target_list)
    if not ok then
      return nil, "failed to store target_list in shm: " .. err
    end

    -- remove all individual statuses
    for _, target in ipairs(old_target_list) do
      local ip, port = target.ip, target.port
      clear_target_data_from_shm(self, ip, port)
    end

    self.targets = {}

    -- raise event for our removed target
    self:raise_event(self.events.clear)

    return true
  end)
end


--- Get the current status of the target.
-- @param ip IP address of the target being checked.
-- @param port the port being checked against.
-- @return `true` if healthy, `false` if unhealthy, or `nil + error` on failure.
function checker:get_target_status(ip, port)

  local target = (self.targets[ip] or EMPTY)[tonumber(port)]
  if not target then
    return nil, "target not found"
  end
  return target.healthy

end


------------------------------------------------------------------------------
-- Health management.
-- Functions that allow reporting of failures/successes for passive checks.
-- @section health-management
------------------------------------------------------------------------------


-- Run the given function holding a lock on the target.
-- WARNING: the callback will run unprotected, so it should never
-- throw an error, but always return `nil + error` instead.
-- @param self The checker object
-- @param ip Target IP
-- @param port Target port
-- @param fn The function to execute
-- @return The results of the function; or nil and an error message
-- in case it fails locking.
local function locking_target(self, ip, port, fn)
  local lock, lock_err = resty_lock:new(self.shm_name, {
                  exptime = 10,  -- timeout after which lock is released anyway
                  timeout = 5,   -- max wait time to acquire lock
                })
  if not lock then
    return nil, "failed to create lock:" .. lock_err
  end
  local lock_key = get_shm_key(self.TARGET_LOCK, ip, port)

  local ok, err = lock:lock(lock_key)
  if not ok then
    return nil, "failed to acquire lock: " .. err
  end

  local final_ok, final_err = fn()

  ok, err = lock:unlock()
  if not ok then
    -- recoverable: not returning this error, only logging it
    self:log(ERR, "failed to release lock '", lock_key, "': ", err)
  end

  return final_ok, final_err
end


-- Return the value 1 for the counter at `idx` in a multi-counter.
-- @param idx The shift index specifying which counter to use.
-- @return The value 1 encoded for the 32-bit multi-counter.
local function ctr_unit(idx)
   return bit.lshift(1, idx)
end

-- Extract the value of the counter at `idx` from multi-counter `val`.
-- @param val A 32-bit multi-counter holding 4 values.
-- @param idx The shift index specifying which counter to get.
-- @return The 8-bit value extracted from the 32-bit multi-counter.
local function ctr_get(val, idx)
   return bit.band(bit.rshift(val, idx), 0xff)
end


-- Increment the healthy or unhealthy counter. If the threshold of occurrences
-- is reached, it changes the status of the target in the shm and posts an
-- event.
-- @param self The checker object
-- @param health_mode "healthy" for the success counter that drives a target
-- towards the healthy state; "unhealthy" for the failure counter.
-- @param ip Target IP
-- @param port Target port
-- @param limit the limit after which target status is changed
-- @param ctr_type the counter to increment, see CTR_xxx constants
-- @return True if succeeded, or nil and an error message.
local function incr_counter(self, health_mode, ip, port, limit, ctr_type)

  -- fail fast on counters that are disabled by configuration
  if limit == 0 then
    return true
  end

  port = tonumber(port)
  local target = (self.targets[ip] or EMPTY)[port]
  if not target then
    -- sync issue: warn, but return success
    self:log(WARN, "trying to increment a target that is not in the list: ", ip, ":", port)
    return true
  end

  if (health_mode == "healthy" and target.healthy) or
     (health_mode == "unhealthy" and not target.healthy) then
    -- No need to count successes when healthy or failures when unhealthy
    return true
  end

  local counter, other, type_name
  if health_mode == "healthy" then
    counter   = self.TARGET_OKS
    other     = self.TARGET_NOKS
    type_name = CTR_NAME_SUCCESS[ctr_type]
  else
    counter   = self.TARGET_NOKS
    other     = self.TARGET_OKS
    type_name = CTR_NAME_FAILURE[ctr_type]
  end

  return locking_target(self, ip, port, function()

    local counter_key = get_shm_key(counter, ip, port)
    local multictr, err = self.shm:incr(counter_key, ctr_unit(ctr_type), 0)
    if err then
      return nil, err
    end

    local ctr = ctr_get(multictr, ctr_type)

    self:log(WARN, health_mode, " ", type_name, " increment (", ctr, "/",
                   limit, ") for ", ip, ":", port)

    if ctr == 1 then
      local other_key = get_shm_key(other, ip, port)
      self.shm:set(other_key, 0)
    end

    if ctr >= limit then
      local status_key = get_shm_key(self.TARGET_STATUS, ip, port)
      self.shm:set(status_key, health_mode == "healthy")
      self:raise_event(self.events[health_mode], ip, port, target.hostname)
    end

    return true

  end)

end


--- Report a health failure.
-- Reports a health failure which will count against the number of occurrences
-- required to make a target "fall". The type of healthchecker,
-- "tcp" or "http" (see `new`) determines against which counter the occurence goes.
-- If `unhealthy.tcp_failures` (for TCP failures) or `unhealthy.http_failures`
-- is set to zero in the configuration, this function is a no-op
-- and returns `true`.
-- @param ip IP address of the target being checked.
-- @param port the port being checked against.
-- @param check (optional) the type of check, either "passive" or "active", default "passive".
-- @return `true` on success, or `nil + error` on failure.
function checker:report_failure(ip, port, check)

  local checks = self.checks[check or "passive"]
  local limit, ctr_type
  if self.type == "tcp" then
    limit = checks.unhealthy.tcp_failures
    ctr_type = CTR_TCP
  else
    limit = checks.unhealthy.http_failures
    ctr_type = CTR_HTTP
  end

  return incr_counter(self, "unhealthy", ip, port, limit, ctr_type)

end


--- Report a health success.
-- Reports a health success which will count against the number of occurrences
-- required to make a target "rise".
-- If `healthy.successes` is set to zero in the configuration,
-- this function is a no-op and returns `true`.
-- @param ip IP address of the target being checked.
-- @param port the port being checked against.
-- @param check (optional) the type of check, either "passive" or "active", default "passive".
-- @return `true` on success, or `nil + error` on failure.
function checker:report_success(ip, port, check)

  local limit = self.checks[check or "passive"].healthy.successes

  return incr_counter(self, "healthy", ip, port, limit, CTR_SUCCESS)

end


--- Report a http response code.
-- How the code is interpreted is based on the configuration for healthy and
-- unhealthy statuses. If it is in neither strategy, it will be ignored.
-- If `healthy.successes` (for healthy HTTP status codes)
-- or `unhealthy.http_failures` (fur unhealthy HTTP status codes)
-- is set to zero in the configuration, this function is a no-op
-- and returns `true`.
-- @param ip IP address of the target being checked.
-- @param port the port being checked against.
-- @param http_status the http statuscode, or nil to report an invalid http response.
-- @param check (optional) the type of check, either "passive" or "active", default "passive".
-- @return `true` on success, `nil` if the status was ignored (not in active or
-- passive health check lists) or `nil + error` on failure.
function checker:report_http_status(ip, port, http_status, check)
  http_status = tonumber(http_status) or 0

  local checks = self.checks[check or "passive"]

  local status_type, limit
  if checks.healthy.http_statuses[http_status] then
    status_type = "healthy"
    limit = checks.healthy.successes
  elseif checks.unhealthy.http_statuses[http_status]
      or http_status == 0 then
    status_type = "unhealthy"
    limit = checks.unhealthy.http_failures
  else
    return
  end

  return incr_counter(self, status_type, ip, port, limit, CTR_HTTP)

end

--- Report a failure on TCP level.
-- If `unhealthy.tcp_failures` is set to zero in the configuration,
-- this function is a no-op and returns `true`.
-- @param ip IP address of the target being checked.
-- @param port the port being checked against.
-- @param operation The socket operation that failed:
-- "connect", "send" or "receive".
-- TODO check what kind of information we get from the OpenResty layer
-- in order to tell these error conditions apart
-- https://github.com/openresty/lua-resty-core/blob/master/lib/ngx/balancer.md#get_last_failure
-- @param check (optional) the type of check, either "passive" or "active", default "passive".
-- @return `true` on success, or `nil + error` on failure.
function checker:report_tcp_failure(ip, port, operation, check)

  local limit = self.checks[check or "passive"].unhealthy.tcp_failures

  -- TODO what do we do with the `operation` information

  return incr_counter(self, "unhealthy", ip, port, limit, CTR_TCP)

end


--- Report a timeout failure.
-- If `unhealthy.timeouts` is set to zero in the configuration,
-- this function is a no-op and returns `true`.
-- @param ip IP address of the target being checked.
-- @param port the port being checked against.
-- @param check (optional) the type of check, either "passive" or "active", default "passive".
-- @return `true` on success, or `nil + error` on failure.
function checker:report_timeout(ip, port, check)

  local limit = self.checks[check or "passive"].unhealthy.timeouts

  return incr_counter(self, "unhealthy", ip, port, limit, CTR_TIMEOUT)

end


--- Sets the current status of the target.
-- This will immediately set the status and clear its counters.
-- @param ip IP address of the target being checked
-- @param port the port being checked against
-- @param mode boolean: `true` for healthy, `false` for unhealthy
-- @return `true` on success, or `nil + error` on failure
function checker:set_target_status(ip, port, mode)
  ip   = tostring(assert(ip, "no ip address provided"))
  port = assert(tonumber(port), "no port number provided")
  assert(type(mode) == "boolean")

  local health_mode = mode and "healthy" or "unhealthy"

  local target = (self.targets[ip] or EMPTY)[port]
  if not target then
    -- sync issue: warn, but return success
    self:log(WARN, "trying to set status for a target that is not in the list: ", ip, ":", port)
    return true
  end

  local oks_key = get_shm_key(self.TARGET_OKS, ip, port)
  local noks_key = get_shm_key(self.TARGET_NOKS, ip, port)
  local status_key = get_shm_key(self.TARGET_STATUS, ip, port)

  local ok, err = locking_target(self, ip, port, function()

    local _, err = self.shm:set(oks_key, 0)
    if err then
      return nil, err
    end

    local _, err = self.shm:set(noks_key, 0)
    if err then
      return nil, err
    end

    self.shm:set(status_key, health_mode == "healthy")
    if err then
      return nil, err
    end

    self:raise_event(self.events[health_mode], ip, port, target.hostname)

    return true

  end)

  if ok then
    self:log(WARN, health_mode, " forced for ", ip, ":", port)
  end
  return ok, err
end


--============================================================================
-- Healthcheck runner
--============================================================================


-- Runs a single healthcheck probe
function checker:run_single_check(ip, port, hostname, healthy)

  self:log(DEBUG, "Checking ", ip, ":", port, " host: [", hostname, "]", " (currently ", healthy and green("healthy") or red("unhealthy"), ")")

  local sock, err = ngx.socket.tcp()
  if not sock then
    self:log(ERR, "failed to create stream socket: ", err)
    return
  end

  sock:settimeout(self.checks.active.timeout * 1000)

  local ok
  ok, err = sock:connect(ip, port)
  if not ok then
    if err == "timeout" then
      sock:close()  -- timeout errors do not close the socket.
      return self:report_timeout(ip, port, "active")
    end
    return self:report_tcp_failure(ip, port, "connect", "active")
  end

  if self.type == "tcp" then
    sock:close()
    return self:report_tcp_success(ip, port, "active")
  end

  -- TODO: implement https

  local path = self.checks.active.http_path
  local host = hostname

  if string.sub(path, 1, 7) == "http://" then
    -- Split absolute path
    local fslash = string.find(path, "/", 8)
    if fslash then
      host = string.sub(path, 8, fslash - 1)
      path = string.sub(path, fslash, -1)
    else
      host = string.sub(path, 8, -1)
      path = "/"
  end

  self:log(DEBUG, "request: host: [", host, "] path: [", path, "]  on ip: [", ip, "]")
  local request = ("GET %s HTTP/1.0\r\nHost: %s\r\n\r\n"):format(path, host)

  local bytes
  bytes, err = sock:send(request)
  if not bytes then
    self:log(ERR, "failed to send http request to '", ip, ":", port, "': ", err)
    if err == "timeout" then
      sock:close()  -- timeout errors do not close the socket.
      return self:report_timeout(ip, port, "active")
    end
    return self:report_tcp_failure(ip, port, "send", "active")
  end

  local status_line
  status_line, err = sock:receive()
  if not status_line then
    self:log(ERR, "failed to receive status line from '", ip, ":", port, "': ", err)
    if err == "timeout" then
      sock:close()  -- timeout errors do not close the socket.
      return self:report_timeout(ip, port, "active")
    end
    return self:report_tcp_failure(ip, port, "receive", "active")
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

  self:log(DEBUG, "Reporting ", ip, ":", port, " (got HTTP ", status, ")")

  return self:report_http_status(ip, port, status, "active")
end

-- executes a work package (a list of checks) sequentially
function checker:run_work_package(work_package)
  for _, target in ipairs(work_package) do
    self:run_single_check(target.ip, target.port, target.hostname, target.healthy)
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
    if idx > self.checks.active.concurrency then idx = 1 end
  end

  -- hand out work-packages to the threads, note the "-1" because this timer
  -- thread will handle the last package itself.
  local threads = {}
  for i = 1, #work_packages - 1 do
    threads[i] = ngx.thread.spawn(self.run_work_package, self, work_packages[i])
  end
  -- run last package myself
  self:run_work_package(work_packages[#work_packages])

  -- wait for everybody to finish
  for _, thread in ipairs(threads) do
    ngx.thread.wait(thread)
  end
end

--============================================================================
-- Internal callbacks, timers and events
--============================================================================
-- The timer callbacks are responsible for checking the status, upon success/
-- failure they will call the health-management functions to deal with the
-- results of the checks.


-- @param health_mode either "healthy" or "unhealthy" to indicate what
-- lock to get.
-- @return `true` on success, or false if the lock was not acquired, or `nil + error`
-- in case of errors
function checker:get_periodic_lock(health_mode)
  local key = self.PERIODIC_LOCK .. health_mode
  local interval = self.checks.active[health_mode].interval

  -- The lock is held for the whole interval to prevent multiple
  -- worker processes from sending the test request simultaneously.
  -- UNLESS: the probing takes longer than the timer interval.
  -- Here we substract the lock expiration time by 1ms to prevent
  -- a race condition with the next timer event.
  local ok, err = self.shm:add(key, true, interval - 0.001)
  if not ok then
    if err == "exists" then
      return false
    end
    self:log(ERR, "failed to add key '", key, "': ", err)
    return nil
  end
  return true
end


--- Active health check callback function.
-- @param premature default openresty param
-- @param self the checker object this timer runs on
-- @param health_mode either "healthy" or "unhealthy" to indicate what check
local function checker_callback(premature, self, health_mode)
  if premature or self.stopping then
    self.timer_count = self.timer_count - 1
    return
  end

  local interval
  if not self:get_periodic_lock(health_mode) then
    -- another worker just ran, or is running the healthcheck
    interval = self.checks.active[health_mode].interval

  else
    -- we're elected to run the active healthchecks
    -- create a list of targets to check, here we can still do this atomically
    local start_time = ngx_now()
    local list_to_check = {}
    local status = (health_mode == "healthy")
    for _, target in ipairs(self.targets) do
      if target.healthy == status then
        list_to_check[#list_to_check + 1] = {
          ip = target.ip,
          port = target.port,
          healthy = target.healthy,
        }
      end
    end

    if not list_to_check[1] then
      self:log(DEBUG, "checking ", health_mode, " targets: nothing to do")
    else
      self:log(DEBUG, "checking ", health_mode, " targets: #", #list_to_check)
      self:active_check_targets(list_to_check)
    end

    local run_time = ngx_now() - start_time
    interval = math.max(0, self.checks.active[health_mode].interval - run_time)
  end

  -- reschedule timer
  local ok, err = utils.gctimer(interval, checker_callback, self, health_mode)
  if not ok then
    self.timer_count = self.timer_count - 1
    self:log(ERR, "failed to re-create '", health_mode, "' timer: ", err)
  end
end

-- Event handler callback
function checker:event_handler(event_name, ip, port, hostname)

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
      self:log(DEBUG, "event: target '", ip, ":", port, "' removed")

    else
      self:log(WARN, "event: trying to remove an unknown target '", ip, ":", port)
    end

  elseif event_name == self.events.healthy or
         event_name == self.events.unhealthy then
    if not target_found then
      -- it is a new target, must add it first
      target_found = { ip = ip, port = port, hostname = hostname }
      self.targets[target_found.ip] = self.targets[target_found.ip] or {}
      self.targets[target_found.ip][target_found.port] = target_found
      self.targets[#self.targets + 1] = target_found
      self:log(DEBUG, "event: target added ", ip, ":", port)
    end
    local health = (event_name == self.events.healthy)
    self:log(DEBUG, "event: target status '", ip, ":", port,
                    "' from '", target_found.healthy, "' to '", health, "'")
    target_found.healthy = health

  elseif event_name == self.events.clear then
    -- clear local cache
    self.targets = {}
    self:log(DEBUG, "event: local cache cleared")

  else
    self:log(WARN, "event: unknown event received '", event_name, "'")
  end
end


------------------------------------------------------------------------------
-- Initializing.
-- @section initializing
------------------------------------------------------------------------------

-- Log a message specific to this checker
-- @param level standard ngx log level constant
function checker:log(level, ...)
  ngx_log(level, worker_color(self.LOG_PREFIX), ...)
end


-- Raises an event for a target status change.
function checker:raise_event(event_name, ip, port, hostname)
  local target = { ip = ip, port = port, hostname = hostname }
  worker_events.post(self.EVENT_SOURCE, event_name, target)
end


--- Stop the background health checks.
-- The timers will be flagged to exit, but will not exit immediately. Only
-- after the current timers have expired they will be marked as stopped.
-- @return `true`
function checker:stop()
  self.stopping = true
  self:log(DEBUG, "timers stopped")
  return true
end


--- Start the background health checks.
-- @return `true`, or `nil + error`.
function checker:start()
  if self.timer_count ~= 0 then
    return nil, "cannot start, " .. self.timer_count .. " (of 2) timers are still running"
  end

  local ok, err
  if self.checks.active.healthy.interval > 0 then
    ok, err = utils.gctimer(0, checker_callback, self, "healthy")
    if not ok then
      return nil, "failed to create 'healthy' timer: " .. err
    end
    self.timer_count = self.timer_count + 1
  end

  if self.checks.active.unhealthy.interval > 0 then
    ok, err = utils.gctimer(0, checker_callback, self, "unhealthy")
    if not ok then
      return nil, "failed to create 'unhealthy' timer: " .. err
    end
    self.timer_count = self.timer_count + 1
  end

  worker_events.unregister(self.ev_callback, self.EVENT_SOURCE)  -- ensure we never double subscribe
  worker_events.register_weak(self.ev_callback, self.EVENT_SOURCE)

  self.stopping = false  -- do this at the end, so if either creation fails, the other stops also
  self:log(DEBUG, "timers started")
  return true
end


--============================================================================
-- Create health-checkers
--============================================================================


local NO_DEFAULT = {}
local MAXNUM = 2^31 - 1


local function fail(ctx, k, msg)
  ctx[#ctx + 1] = k
  error(table.concat(ctx, ".") .. ": " .. msg, #ctx + 1)
end


local function fill_in_settings(opts, defaults, ctx)
  ctx = ctx or {}
  local obj = {}
  for k, default in pairs(defaults) do
    local v = opts[k]

    -- basic type-check of configuration
    if default ~= NO_DEFAULT
       and v ~= nil
       and type(v) ~= type(default) then
      fail(ctx, k, "invalid value")
    end

    if v then
      if type(v) == "table" then
        if default[1] then -- do not recurse on arrays
          obj[k] = v
        else
          ctx[#ctx + 1] = k
          obj[k] = fill_in_settings(v, default, ctx)
          ctx[#ctx + 1] = nil
        end
      else
        if type(v) == "number" and (v < 0 or v > MAXNUM) then
          fail(ctx, k, "must be between 0 and " .. MAXNUM)
        end
        obj[k] = v
      end
    elseif default ~= NO_DEFAULT then
      obj[k] = default
    end

  end
  return obj
end


local defaults = {
  name = NO_DEFAULT,
  shm_name = NO_DEFAULT,
  type = "http",
  checks = {
    active = {
      timeout = 1,
      concurrency = 10,
      http_path = "/",
      healthy = {
        interval = 0, -- 0 = disabled by default
        http_statuses = { 200, 302 },
        successes = 2,
      },
      unhealthy = {
        interval = 0, -- 0 = disabled by default
        http_statuses = { 429, 404,
                          500, 501, 502, 503, 504, 505 },
        tcp_failures = 2,
        timeouts = 3,
        http_failures = 5,
      },
    },
    passive = {
      healthy = {
        http_statuses = { 200, 201, 202, 203, 204, 205, 206, 207, 208, 226,
                          300, 301, 302, 303, 304, 305, 306, 307, 308 },
        successes = 5,
      },
      unhealthy = {
        http_statuses = { 429, 500, 503 },
        tcp_failures = 2,
        timeouts = 7,
        http_failures = 5,
      },
    },
  },
}


local function to_set(tbl, key)
  local set = {}
  for _, item in ipairs(tbl[key]) do
    set[item] = true
  end
  tbl[key] = set
end


--- Creates a new health-checker instance.
-- It will be started upon creation.
--
-- *NOTE*: the returned `checker` object must be anchored, if not it will be
-- removed by Lua's garbage collector and the healthchecks will cease to run.
-- @param opts table with checker options. Options are:
--
-- * `name`: name of the health checker
-- * `shm_name`: the name of the `lua_shared_dict` specified in the Nginx configuration to use
-- * `type`: "http", "https" or "tcp"
-- * `checks.active.timeout`: socket timeout for active checks (in seconds)
-- * `checks.active.concurrency`: number of targets to check concurrently
-- * `checks.active.http_path`: path to use in `GET` HTTP request to run on active checks
-- * `checks.active.healthy.interval`: interval between checks for healthy targets (in seconds)
-- * `checks.active.healthy.http_statuses`: which HTTP statuses to consider a success
-- * `checks.active.healthy.successes`: number of successes to consider a target healthy
-- * `checks.active.unhealthy.interval`: interval between checks for unhealthy targets (in seconds)
-- * `checks.active.unhealthy.http_statuses`: which HTTP statuses to consider a failure
-- * `checks.active.unhealthy.tcp_failures`: number of TCP failures to consider a target unhealthy
-- * `checks.active.unhealthy.timeouts`: number of timeouts to consider a target unhealthy
-- * `checks.active.unhealthy.http_failures`: number of HTTP failures to consider a target unhealthy
-- * `checks.passive.healthy.http_statuses`: which HTTP statuses to consider a failure
-- * `checks.passive.healthy.successes`: number of successes to consider a target healthy
-- * `checks.passive.unhealthy.http_statuses`: which HTTP statuses to consider a success
-- * `checks.passive.unhealthy.tcp_failures`: number of TCP failures to consider a target unhealthy
-- * `checks.passive.unhealthy.timeouts`: number of timeouts to consider a target unhealthy
-- * `checks.passive.unhealthy.http_failures`: number of HTTP failures to consider a target unhealthy
--
-- If any of the health counters above (e.g. `checks.passive.unhealthy.timeouts`)
-- is set to zero, the according category of checks is not taken to account.
-- This way active or passive health checks can be disabled selectively.
--
-- @return checker object, or `nil + error`
function _M.new(opts)

  assert(worker_events.configured(), "please configure the " ..
      "'lua-resty-worker-events' module before using 'lua-resty-healthcheck'")

  local self = fill_in_settings(opts, defaults)

  assert(self.name, "required option 'name' is missing")
  assert(self.shm_name, "required option 'shm_name' is missing")
  assert(({ http = true, tcp = true })[self.type], "type can only be 'http' " ..
          "or 'tcp', got '" .. tostring(self.type) .. "'")

  self.shm = ngx.shared[tostring(opts.shm_name)]
  assert(self.shm, ("no shm found by name '%s'"):format(opts.shm_name))

  -- other properties
  self.targets = nil     -- list of targets, initially loaded, maintained by events
  self.events = nil      -- hash table with supported events (prevent magic strings)
  self.stopping = true   -- flag to indicate to timers to stop checking
  self.timer_count = 0   -- number of running timers
  self.ev_callback = nil -- callback closure per checker instance

  -- Convert status lists to sets
  to_set(self.checks.active.unhealthy, "http_statuses")
  to_set(self.checks.active.healthy, "http_statuses")
  to_set(self.checks.passive.unhealthy, "http_statuses")
  to_set(self.checks.passive.healthy, "http_statuses")

  -- decorate with methods and constants
  self.events = EVENTS
  for k,v in pairs(checker) do
    self[k] = v
  end

  -- prepare shm keys
  self.TARGET_STATUS    = SHM_PREFIX .. self.name .. ":status"
  self.TARGET_OKS       = SHM_PREFIX .. self.name .. ":oks"
  self.TARGET_NOKS      = SHM_PREFIX .. self.name .. ":noks"
  self.TARGET_LIST      = SHM_PREFIX .. self.name .. ":target_list"
  self.TARGET_LIST_LOCK = SHM_PREFIX .. self.name .. ":target_list_lock"
  self.TARGET_LOCK      = SHM_PREFIX .. self.name .. ":target_lock"
  self.PERIODIC_LOCK    = SHM_PREFIX .. self.name .. ":period_lock:"
  -- prepare constants
  self.EVENT_SOURCE     = EVENT_SOURCE_PREFIX .. " [" .. self.name .. "]"
  self.LOG_PREFIX       = LOG_PREFIX .. "(" .. self.name .. ") "

  -- register for events, and directly after load initial target list
  -- order is important!
  do
    self.ev_callback = function(data, event)
      -- just a wrapper to be able to access `self` as a closure
      return self:event_handler(event, data.ip, data.port, data.hostname)
    end
    worker_events.register_weak(self.ev_callback, self.EVENT_SOURCE)

    -- Lock the list, in case it is being cleared by another worker
    local ok, err = locking_target_list(self, function(target_list)

      self.targets = target_list
      self:log(DEBUG, "Got initial target list (", #self.targets, " targets)")

      -- load individual statuses
      for _, target in ipairs(self.targets) do
        target.healthy = self.shm:get(get_shm_key(self.TARGET_STATUS,
                                              target.ip, target.port))
        self:log(DEBUG, "Got initial status ", target.healthy, " ", target.ip, ":", target.port)
        -- fill-in the hash part for easy lookup
        self.targets[target.ip] = self.targets[target.ip] or {}
        self.targets[target.ip][target.port] = target
      end

      return true
    end)
    if not ok then
      self:log(ERR, "Error loading initial target list: ", err)
    end

    -- handle events to sync up in case there was a change by another worker
    worker_events:poll()
  end

  -- start timers
  local ok, err = self:start()
  if not ok then
    self:stop()
    return nil, err
  end

  -- TODO: push entire config in debug level logs
  self:log(DEBUG, "Healthchecker started!")
  return self
end


return _M
