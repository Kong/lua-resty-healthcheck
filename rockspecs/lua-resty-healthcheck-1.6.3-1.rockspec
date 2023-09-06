package = "lua-resty-healthcheck"
version = "1.6.3-1"
source = {
  url = "git+https://github.com/Kong/lua-resty-healthcheck.git",
  tag = "1.6.3"
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
  "penlight >= 1.9.2",
  "lua-resty-timer ~> 1",
}
build = {
  type = "builtin",
  modules = {
    ["resty.healthcheck"] = "lib/resty/healthcheck.lua",
  }
}
