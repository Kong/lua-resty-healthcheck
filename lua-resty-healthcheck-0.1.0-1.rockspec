package = "lua-resty-healthcheck"
version = "0.1.0-1"
source = {
   url = "https://github.com/Mashape/lua-resty-healthcheck/archive/0.1.0.tar.gz",
   dir = "lua-resty-healthcheck-0.1.0"
}
description = {
   summary = "Healthchecks for OpenResty to check upstream service status",
   detailed = [[
      lua-resty-healthcheck is a module that can check upstream service
      availability by sending requests and validating responses at timed
      intervals.
   ]],
   license = "Apache 2.0",
   homepage = "https://github.com/Mashape/lua-resty-healthcheck"
}
dependencies = {
}
build = {
   type = "builtin",
   modules = { 
     ["resty.healthcheck"]       = "lib/resty/healthcheck.lua",
     ["resty.healthcheck.utils"] = "lib/resty/healthcheck/utils.lua",
   }
}
