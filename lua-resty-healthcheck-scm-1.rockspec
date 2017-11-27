package = "lua-resty-healthcheck"
version = "scm-1"
source = {
   url = "git://github.com/kong/lua-resty-healthcheck",
}
description = {
   summary = "Healthchecks for OpenResty to check upstream service status",
   detailed = [[
      lua-resty-healthcheck is a module that can check upstream service
      availability by sending requests and validating responses at timed
      intervals.
   ]],
   license = "Apache 2.0",
   homepage = "https://github.com/Kong/lua-resty-healthcheck"
}
dependencies = {
  "lua-resty-worker-events == 0.3.1",
}
build = {
   type = "builtin",
   modules = {
     ["resty.healthcheck"]       = "lib/resty/healthcheck.lua",
     ["resty.healthcheck.utils"] = "lib/resty/healthcheck/utils.lua",
   }
}
