# lua-resty-healthcheck

[![Build Status][badge-travis-image]][badge-travis-url]

A health check library for OpenResty.

# Status

This library is still under early development.

# Synopsis

```nginx
http {
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
    init_worker_by_lua_block {
        local we = require "resty.worker.events"
        local ok, err = we.configure{
            shm = "my_worker_events",
            interval = 0.1,
        }
        if not ok then
            ngx.log(ngx.ERR, "failed to configure worker events: ", err)
            return
        end

        ngx.timer.at(0, function()
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "test_checker",
                shm_name = "test_shm",
                checks = {
                    active = {
                        http_request = "GET /status HTTP/1.0\r\nHost: example.com\r\n\r\n",
                        healthy = {
                            interval = 0.5
                        },
                        unhealthy = {
                            interval = 0.5
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2112)
            if not ok then
                ngx.log(ngx.ERR, err)
            end
            local ok, err = checker:add_target("127.0.0.1", 5150)
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        end)
    }
}
```

# Description

This library supports performing active and passive health checks on arbitrary hosts.

Control of the library happens via its programmatic API. Consumption of its events
happens via the [lua-resty-worker-events](https://github.com/Mashape/lua-resty-worker-events) library.

For active health checks, targets are added using `checker:add_target(host, port)`.
Changes in status ("healthy" or "unhealthy") are broadcasted via worker-events.

For passive health checks, the library receives explicit notifications via its
programmatic API using functions such as `checker:report_http_status(host, port, status)`.

See the [online LDoc documentation](http://mashape.github.io/lua-resty-healthcheck)
for the complete API.

# Copyright and License

## License

```
Copyright 2017 Kong Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

[badge-travis-url]: https://travis-ci.com/Mashape/lua-resty-healthcheck/branches
[badge-travis-image]: https://travis-ci.com/Mashape/lua-resty-healthcheck.svg?token=cpcsrmGmJZdztxDeoJqq&branch=master
