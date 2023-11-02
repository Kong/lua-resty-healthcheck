package = "lua-resty-healthcheck"
version = "1.4.2-1"
source = {
   url = "https://github.com/Kong/lua-resty-healthcheck/archive/1.4.2.tar.gz",
   dir = "lua-resty-healthcheck-1.4.2"
}
description = {
   summary = "Healthchecks for OpenResty to check upstream service status",
   detailed = [[
      lua-resty-healthcheck is a module that can check upstream service
      availability by sending requests and validating responses at timed
      intervals.
   ]],
   homepage = "https://github.com/Kong/lua-resty-healthcheck",
   license = "Apache 2.0"
}
dependencies = {
   "lua-resty-worker-events == 1.0.0",
   "penlight >= 1.9.2",
   "lua-resty-timer ~> 1",
}
build = {
   type = "builtin",
   modules = {
      ["resty.healthcheck"] = "lib/resty/healthcheck.lua",
   }
}
