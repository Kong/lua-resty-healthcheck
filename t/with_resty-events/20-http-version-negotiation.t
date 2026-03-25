use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * 38;

my $pwd = cwd();
$ENV{TEST_NGINX_SERVROOT} = server_root();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;

    init_worker_by_lua_block {
        local we = require "resty.events.compat"
        assert(we.configure({
            unique_timeout = 5,
            broker_id = 0,
            listening = "unix:$ENV{TEST_NGINX_SERVROOT}/worker_events.sock"
        }))
        assert(we.configured())
    }

    server {
        server_name kong_worker_events;
        listen unix:$ENV{TEST_NGINX_SERVROOT}/worker_events.sock;
        access_log off;
        location / {
            content_by_lua_block {
                require("resty.events.compat").run()
            }
        }
    }
};

run_tests();

__DATA__



=== TEST 1: 505 auto-fallback, HTTP/1.0-only server, target stays healthy
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2114;
        location = /status {
            content_by_lua_block {
                if ngx.var.server_protocol == "HTTP/1.1" then
                    return ngx.exit(505)
                end
                ngx.exit(200)
            }
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1,
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 3,
                        }
                    },
                }
            })
            ngx.sleep(2)
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, false)
            ngx.sleep(0.6)
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
returned 505 on HTTP/1.1, retrying with HTTP/1.0



=== TEST 2: 426 auto-upgrade, server switches from HTTP/1.0-only to HTTP/1.1-only
--- timeout: 5
--- http_config eval
qq{
    $::HttpConfig

    lua_shared_dict mock_state 1m;

    server {
        listen 2114;
        location = /status {
            content_by_lua_block {
                local phase = ngx.shared.mock_state:get("phase") or 1
                if phase == 1 then
                    -- Phase 1: only accept HTTP/1.0
                    if ngx.var.server_protocol == "HTTP/1.1" then
                        return ngx.exit(505)
                    end
                    ngx.exit(200)
                else
                    -- Phase 2: only accept HTTP/1.1
                    if ngx.var.server_protocol ~= "HTTP/1.1" then
                        return ngx.exit(426)
                    end
                    ngx.exit(200)
                end
            }
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1,
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 3,
                        }
                    },
                }
            })
            ngx.sleep(2)
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, false)
            -- Phase 1: server only supports HTTP/1.0
            ngx.sleep(0.6)
            local status1 = checker:get_target_status("127.0.0.1", 2114)
            ngx.say("phase1: ", status1)  -- true (healthy via 1.0 fallback)

            -- Switch to phase 2: server now only supports HTTP/1.1
            ngx.shared.mock_state:set("phase", 2)
            ngx.sleep(0.6)
            local status2 = checker:get_target_status("127.0.0.1", 2114)
            ngx.say("phase2: ", status2)  -- true (healthy via 1.1 upgrade)
        }
    }
--- request
GET /t
--- response_body
phase1: true
phase2: true
--- error_log
returned 505 on HTTP/1.1, retrying with HTTP/1.0
returned 426 on HTTP/1.0, retrying with HTTP/1.1



=== TEST 3: version caching, no repeated retries after stabilization
--- timeout: 5
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2114;
        location = /status {
            content_by_lua_block {
                if ngx.var.server_protocol == "HTTP/1.1" then
                    return ngx.exit(505)
                end
                ngx.exit(200)
            }
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1,
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 3,
                        }
                    },
                }
            })
            ngx.sleep(2)
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, false)
            -- Wait long enough for multiple check intervals so caching takes effect
            ngx.sleep(1.5)
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log eval
[
    qr/returned 505 on HTTP\/1\.1, retrying with HTTP\/1\.0/,
    qr/healthy SUCCESS increment/,
]
--- no_error_log eval
qr/returned 505 on HTTP\/1\.1, retrying with HTTP\/1\.0.*returned 505 on HTTP\/1\.1, retrying with HTTP\/1\.0/s



=== TEST 4: permanent failure, both versions return 505, target goes unhealthy
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2114;
        location = /status {
            return 505;
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1,
                            successes = 3,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 3,
                        }
                    },
                }
            })
            ngx.sleep(2)
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, true)
            ngx.sleep(0.6)
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- false
        }
    }
--- request
GET /t
--- response_body
false
--- error_log
returned 505 on HTTP/1.1, retrying with HTTP/1.0
unhealthy HTTP increment (1/3) for '127.0.0.1(127.0.0.1:2114)'
unhealthy HTTP increment (2/3) for '127.0.0.1(127.0.0.1:2114)'
unhealthy HTTP increment (3/3) for '127.0.0.1(127.0.0.1:2114)'
event: target status '127.0.0.1(127.0.0.1:2114)' from 'true' to 'false'



=== TEST 5: normal HTTP/1.1, no version negotiation triggered
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2114;
        location = /status {
            return 200;
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1,
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 3,
                        }
                    },
                }
            })
            ngx.sleep(2)
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, false)
            ngx.sleep(0.6)
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- no_error_log
retrying with HTTP/



=== TEST 6: 426 on HTTP/1.1, retried once then cached (server wants HTTP/2)
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2114;
        location = /status {
            return 426;
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1,
                            successes = 3,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 3,
                        }
                    },
                }
            })
            ngx.sleep(2)
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, true)
            ngx.sleep(0.6)
            -- 426 is not in the default healthy or unhealthy lists,
            -- so status should remain unchanged (still true)
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
retrying with HTTP/



=== TEST 7: non-standard server, returns 400 on HTTP/1.1, 200 on HTTP/1.0
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2114;
        location = /status {
            content_by_lua_block {
                if ngx.var.server_protocol == "HTTP/1.1" then
                    return ngx.exit(400)
                end
                ngx.exit(200)
            }
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1,
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 3,
                        }
                    },
                }
            })
            ngx.sleep(2)
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, false)
            ngx.sleep(0.6)
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
returned 400 on HTTP/1.1, retrying with HTTP/1.0



=== TEST 8: genuinely unhealthy server (500 on both versions), retries once then caches
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2114;
        location = /status {
            return 500;
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1,
                            successes = 3,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 3,
                        }
                    },
                }
            })
            ngx.sleep(2)
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, true)
            ngx.sleep(0.6)
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- false
        }
    }
--- request
GET /t
--- response_body
false
--- error_log
unhealthy HTTP increment (1/3) for '127.0.0.1(127.0.0.1:2114)'
unhealthy HTTP increment (2/3) for '127.0.0.1(127.0.0.1:2114)'
unhealthy HTTP increment (3/3) for '127.0.0.1(127.0.0.1:2114)'
event: target status '127.0.0.1(127.0.0.1:2114)' from 'true' to 'false'



=== TEST 9: failed retry reports original status, not retry status
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2114;
        location = /status {
            content_by_lua_block {
                if ngx.var.server_protocol == "HTTP/1.1" then
                    return ngx.exit(418)
                end
                ngx.exit(500)
            }
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1,
                            successes = 3,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 3,
                        }
                    },
                }
            })
            ngx.sleep(2)
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, true)
            ngx.sleep(0.6)
            -- 418 (original) is not in any list, so target stays healthy.
            -- Without the fix, retry's 500 would be reported and cause
            -- unhealthy increments.
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
returned 418 on HTTP/1.1, retrying with HTTP/1.0
--- no_error_log
unhealthy HTTP increment
