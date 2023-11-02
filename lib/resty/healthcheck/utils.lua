--------------------------------------------------------------------------
-- Utilities used by the healthcheck library.
--
-- Code originally from https://github.com/Kong/lua-resty-dns-client
-- @copyright 2017 Kong Inc.
-- @author Hisham Muhammad, Thijs Schreijer
-- @license Apache 2.0

local timer_at = ngx.timer.at

local _M = {}

--------------------------------------------------------
-- GC'able timer implementation with 'self'
--------------------------------------------------------
local timer_registry = setmetatable({},{ __mode = "v" })
local timer_id = 0

local timer_callback = function(premature, cb, id, ...)
  local self = timer_registry[id]
  if not self then return end  -- GC'ed, nothing more to do
  timer_registry[id] = nil
  return cb(premature, self, ...)
end

--- A garbage-collectible timer implementation.
-- Provides a timer that can be attached to an object, and GC'ed along
-- with that object, as opposed to regular timers that keep running and
-- prevent the object from being GC'ed.
-- @param t time in ms
-- @param cb callback for the timer. The signature is `function(premature, self, ...)`
-- @param self the object the timer belongs to
-- @param ... any additional parameters to pass to the timer callback
-- @return timer handle (same as `ngx.timer.at`)
_M.gctimer = function(t, cb, self, ...)
  assert(type(cb) == "function", "expected arg #2 to be a function")
  assert(type(self) == "table", "expected arg #3 to be a table")
  timer_id = timer_id + 1
  timer_registry[timer_id] = self
  -- if in the call below we'd be passing `self` instead of the scalar `timer_id`, it
  -- would prevent the whole `self` object from being garbage collected because
  -- it is anchored on the timer.
  return timer_at(t, timer_callback, cb, timer_id, ...)
end


return _M
