package = "lua-resty-healthcheck"
version = "1.1.2-1"
source = {
   url = "https://github.com/Kong/lua-resty-healthcheck/archive/1.1.2.tar.gz",
   tag = "1.1.2",
   dir = "lua-resty-healthcheck-1.1.2"
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
   "lua-resty-worker-events >= 0.3.2"
}
build = {
   type = "builtin",
   modules = {
      ["resty.healthcheck"] = "lib/resty/healthcheck.lua",
      ["resty.healthcheck.utils"] = "lib/resty/healthcheck/utils.lua"
   }
}
