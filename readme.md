# lua-resty-healthcheck

![legacy version](https://img.shields.io/luarocks/v/kong/lua-resty-healthcheck/1.6.1-1?style=flat-square)
![Release 1.6.x](https://github.com/Kong/lua-resty-healthcheck/actions/workflows/build_and_test_with_resty_events.yml/badge.svg?branch=release/1.6.x)
![License](https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square)
![Twitter Follow](https://img.shields.io/twitter/follow/thekonginc?style=social)

A health check library for OpenResty.

## Synopsis

```nginx
http {
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
    init_worker_by_lua_block {

        local we = require "resty.worker.events"
        local ok, err = we.configure({
            shm = "my_worker_events",
            interval = 0.1
        })
        if not ok then
            ngx.log(ngx.ERR, "failed to configure worker events: ", err)
            return
        end

        local healthcheck = require("resty.healthcheck")
        local checker = healthcheck.new({
            name = "testing",
            shm_name = "test_shm",
            checks = {
                active = {
                    type = "https",
                    http_path = "/status",
                    healthy  = {
                        interval = 2,
                        successes = 1,
                    },
                    unhealthy  = {
                        interval = 1,
                        http_failures = 2,
                    }
                },
            }
        })

        local ok, err = checker:add_target("127.0.0.1", 8080, "example.com", false)

        local handler = function(target, eventname, sourcename, pid)
            ngx.log(ngx.DEBUG,"Event from: ", sourcename)
            if eventname == checker.events.remove
                -- a target was removed
                ngx.log(ngx.DEBUG,"Target removed: ",
                    target.ip, ":", target.port, " ", target.hostname)
            elseif eventname == checker.events.healthy
                -- target changed state, or was added
                ngx.log(ngx.DEBUG,"Target switched to healthy: ",
                    target.ip, ":", target.port, " ", target.hostname)
            elseif eventname ==  checker.events.unhealthy
                -- target changed state, or was added
                ngx.log(ngx.DEBUG,"Target switched to unhealthy: ",
                    target.ip, ":", target.port, " ", target.hostname)
            else
                -- unknown event
            end
        end
    }
}
```

## Description

This library supports performing active and passive health checks on arbitrary hosts.

Control of the library happens via its programmatic API. Consumption of its events
happens via the [lua-resty-worker-events](https://github.com/Kong/lua-resty-worker-events) library.

Targets are added using `checker:add_target(host, port)`.
Changes in status ("healthy" or "unhealthy") are broadcasted via worker-events.

Active checks are executed in the background based on the specified timer intervals.

For passive health checks, the library receives explicit notifications via its
programmatic API using functions such as `checker:report_http_status(host, port, status)`.

See the [online LDoc documentation](http://kong.github.io/lua-resty-healthcheck)
for the complete API.

## History

Versioning is strictly based on [Semantic Versioning](https://semver.org/)

### 1.6.3 (06-Sep-2023)

* Feature: Added support for https_sni [#49](https://github.com/Kong/lua-resty-healthcheck/pull/49) (backport)
* Fix: Use OpenResty API for mTLS [#99](https://github.com/Kong/lua-resty-healthcheck/pull/99) (backport)

### 1.6.2 (17-Nov-2022)

* Fix: avoid raising worker events for new targets that were marked for delayed
  removal, i.e. targets that already exist in memory only need the removal flag
  cleared when added back. [#122](https://github.com/Kong/lua-resty-healthcheck/pull/122)

### 1.6.1 (25-Jul-2022)

* Fix: improvements to ensure the proper securing of shared resources to avoid
  race conditions and clearly report failure states.
  [#112](https://github.com/Kong/lua-resty-healthcheck/pull/112),
  [#113](https://github.com/Kong/lua-resty-healthcheck/pull/113),
  [#114](https://github.com/Kong/lua-resty-healthcheck/pull/114).
* Fix: reduce the frequency of checking for unused targets, reducing the number
  of locks created. [#116](https://github.com/Kong/lua-resty-healthcheck/pull/116)
* Fix accept any [lua-resty-events](https://github.com/Kong/lua-resty-events)
  `0.1.x` release. [#118](https://github.com/Kong/lua-resty-healthcheck/pull/118)

### 1.6.0 (27-Jun-2022)

* Feature: introduce support to [lua-resty-events](https://github.com/Kong/lua-resty-events)
  module in addition to [lua-resty-worker-events](https://github.com/Kong/lua-resty-worker-events)
  support. With this addition, the lua-resty-healthcheck luarocks package does
  not require a specific event-sharing module anymore, but you are still
  required to provide either lua-resty-worker-events or lua-resty-events.
  [#105](https://github.com/Kong/lua-resty-healthcheck/pull/105)
* Change: if available, lua-resty-healthcheck now uses `string.buffer`, the new LuaJIT's
  serialization API. If it is unavailable, lua-resty-healthcheck fallbacks to
  cjson.  [#109](https://github.com/Kong/lua-resty-healthcheck/pull/109)

### 1.5.1 (23-Mar-2022)

* Fix: avoid breaking active health checks when adding or removing targets.
  [#93](https://github.com/Kong/lua-resty-healthcheck/pull/93)

### 1.5.0 (09-Feb-2022)

* New option `checks.active.headers` supports one or more lists of values indexed by
  header name. [#87](https://github.com/Kong/lua-resty-healthcheck/pull/87)
* Introduce dealyed_clear() function, used to remove addresses after a time interval.
  This function may be used when an address is being removed but may be added again
  before the interval expires, keeping its health status.
  [#88](https://github.com/Kong/lua-resty-healthcheck/pull/88)

### 1.4.3 (31-Mar-2022)

* Fix: avoid breaking active health checks when adding or removing targets.
  [#100](https://github.com/Kong/lua-resty-healthcheck/pull/100)

### 1.4.2 (29-Jun-2021)

* Fix: prevent new active checks being scheduled while a health check is running.
  [#72](https://github.com/Kong/lua-resty-healthcheck/pull/72)
* Fix: remove event watcher when stopping an active health check.
  [#74](https://github.com/Kong/lua-resty-healthcheck/pull/74); fixes Kong issue
  [#7406](https://github.com/Kong/kong/issues/7406)

### 1.4.1 (17-Feb-2021)

* Fix: make sure that a single worker will actively check hosts' statuses.
  [#67](https://github.com/Kong/lua-resty-healthcheck/pull/67)

### 1.4.0 (07-Jan-2021)

* Use a single timer to actively health check targets. This reduces the number
  of timers used by health checkers, as they used to use two timers by each
  target. [#62](https://github.com/Kong/lua-resty-healthcheck/pull/62)

### 1.3.0 (17-Jun-2020)

* Adds support to mTLS to active healthchecks. This feature  can be used adding
  the fields `ssl_cert` and `ssl_key`, with certificate and key respectively,
  when creating a new healthcheck object.
  [#41](https://github.com/Kong/lua-resty-healthcheck/pull/41)

### 1.2.0 (13-Feb-2020)

 * Adds `set_all_target_statuses_for_hostname`, which sets the targets for
   all entries with a given hostname at once.

### 1.1.2 (19-Dec-2019)

 * Fix: when `ngx.sleep` API is not available (e.g. in the log phase) it is not
   possible to lock using lua-resty-lock and any function that needs exclusive
   access would fail. This fix adds a retry method that starts a new light
   thread, which has access to `ngx.sleep`, to lock the critical path.
   [#37](https://github.com/Kong/lua-resty-healthcheck/pull/37);

### 1.1.1 (14-Nov-2019)

 * Fix: fail when it is not possible to get exclusive access to the list of
   targets. This fix prevents that workers get to an inconsistent state.
   [#34](https://github.com/Kong/lua-resty-healthcheck/pull/34);

### 1.1.0 (30-Sep-2019)

 * Add support for setting the custom `Host` header to be used for active checks.
 * Fix: log error on SSL Handshake failure
   [#28](https://github.com/Kong/lua-resty-healthcheck/pull/28);

### 1.0.0 (05-Jul-2019)

 * BREAKING: all API functions related to hosts require a `hostname` argument
   now. This way different hostnames listening on the same IP and ports
   combination do not have an effect on each other.
 * Fix: fix reporting active TCP probe successes
   [#20](https://github.com/Kong/lua-resty-healthcheck/pull/20);
   fixes issue [#19](https://github.com/Kong/lua-resty-healthcheck/issues/19)

### 0.6.1 (04-Apr-2019)

 * Fix: set up event callback only after target list is loaded
   [#18](https://github.com/Kong/lua-resty-healthcheck/pull/18);
   fixes Kong issue [#4453](https://github.com/Kong/kong/issues/4453)

### 0.6.0 (26-Sep-2018)

 * Introduce `checks.active.https_verify_certificate` field.
   It is `true` by default; setting it to `false` disables certificate
   verification in active healthchecks over HTTPS.

### 0.5.0 (25-Jul-2018)

 * Add support for `https` -- thanks @gaetanfl for the PR!
 * Introduce separate `checks.active.type` and `checks.passive.type` fields;
   the top-level `type` field is still supported as a fallback but is now
   deprecated.

### 0.4.2 (23-May-2018)

 * Fix `Host` header in active healthchecks

### 0.4.1 (21-May-2018)

 * Fix internal management of healthcheck counters

### 0.4.0 (20-Mar-2018)

 * Correct setting of defaults in `http_statuses`
 * Type and bounds checking to `checks` table

### 0.3.0 (18-Dec-2017)

 * Disable individual checks by setting their counters to 0

### 0.2.0 (30-Nov-2017)

 * Adds `set_target_status`

### 0.1.0 (27-Nov-2017) Initial release

 * Initial upload

## Copyright and License

```
Copyright 2017-2022 Kong Inc.

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

[badge-travis-url]: https://travis-ci.org/Kong/lua-resty-healthcheck/branches
[badge-travis-image]: https://travis-ci.org/Kong/lua-resty-healthcheck.svg?branch=master
