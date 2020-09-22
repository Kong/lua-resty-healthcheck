package = "lua-resty-healthcheck"
version = "scm-1"
source = {
  url = "git://github.com/kong/lua-resty-healthcheck",
  branch = "master",
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
  "lua-resty-worker-events ~> 2",
  "penlight ~> 1.7",
  "lua-resty-timer ~> 1",
}
build = {
  type = "builtin",
  modules = {
    ["resty.healthcheck"] = "lib/resty/healthcheck.lua",
  }
}
