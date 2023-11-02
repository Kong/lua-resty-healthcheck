use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * 41;

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



=== TEST 1: report_http_status() failures active + passive
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2119;
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
                            interval = 999, -- we don't want active checks
                            successes = 3,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2119, nil, true)
            local ok, err = checker:add_target("127.0.0.1", 2113, nil, true)
            ngx.sleep(0.01)
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "active")
            checker:report_http_status("127.0.0.1", 2113, nil, 500, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "active")
            checker:report_http_status("127.0.0.1", 2113, nil, 500, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "active")
            checker:report_http_status("127.0.0.1", 2113, nil, 500, "passive")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2119))  -- false
            ngx.say(checker:get_target_status("127.0.0.1", 2113))  -- false
        }
    }
--- request
GET /t
--- response_body
false
false
--- error_log
unhealthy HTTP increment (1/3) for '(127.0.0.1:2119)'
unhealthy HTTP increment (2/3) for '(127.0.0.1:2119)'
unhealthy HTTP increment (3/3) for '(127.0.0.1:2119)'
event: target status '(127.0.0.1:2119)' from 'true' to 'false'
unhealthy HTTP increment (1/3) for '(127.0.0.1:2113)'
unhealthy HTTP increment (2/3) for '(127.0.0.1:2113)'
unhealthy HTTP increment (3/3) for '(127.0.0.1:2113)'
event: target status '(127.0.0.1:2113)' from 'true' to 'false'



=== TEST 2: report_http_status() successes active + passive
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2119;
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
                            interval = 999, -- we don't want active checks
                            successes = 4,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 4,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2119, nil, false)
            local ok, err = checker:add_target("127.0.0.1", 2113, nil, false)
            ngx.sleep(0.01)
            checker:report_http_status("127.0.0.1", 2119, nil, 200, "active")
            checker:report_http_status("127.0.0.1", 2113, nil, 200, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 200, "active")
            checker:report_http_status("127.0.0.1", 2113, nil, 200, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 200, "active")
            checker:report_http_status("127.0.0.1", 2113, nil, 200, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 200, "active")
            checker:report_http_status("127.0.0.1", 2113, nil, 200, "passive")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2119))  -- true
            ngx.say(checker:get_target_status("127.0.0.1", 2113))  -- true
        }
    }
--- request
GET /t
--- response_body
true
true
--- error_log
healthy SUCCESS increment (1/4) for '(127.0.0.1:2119)'
healthy SUCCESS increment (2/4) for '(127.0.0.1:2119)'
healthy SUCCESS increment (3/4) for '(127.0.0.1:2119)'
healthy SUCCESS increment (4/4) for '(127.0.0.1:2119)'
event: target status '(127.0.0.1:2119)' from 'false' to 'true'
healthy SUCCESS increment (1/4) for '(127.0.0.1:2113)'
healthy SUCCESS increment (2/4) for '(127.0.0.1:2113)'
healthy SUCCESS increment (3/4) for '(127.0.0.1:2113)'
healthy SUCCESS increment (4/4) for '(127.0.0.1:2113)'
event: target status '(127.0.0.1:2113)' from 'false' to 'true'


=== TEST 3: report_http_status() with success is a nop when passive.healthy.successes == 0
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2119;
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
                            interval = 999, -- we don't want active checks
                            successes = 4,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 0,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2119, nil, false)
            ngx.sleep(0.01)
            checker:report_http_status("127.0.0.1", 2119, nil, 200, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 200, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 200, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 200, "passive")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2119, nil))  -- false
        }
    }
--- request
GET /t
--- response_body
false
--- no_error_log
healthy SUCCESS increment
event: target status '127.0.0.1 (127.0.0.1:2119)' from 'false' to 'true'


=== TEST 4: report_http_status() with success is a nop when active.healthy.successes == 0
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2119;
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
                            interval = 999, -- we don't want active checks
                            successes = 0,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 4,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2119, nil, false)
            ngx.sleep(0.01)
            checker:report_http_status("127.0.0.1", 2119, nil, 200, "active")
            checker:report_http_status("127.0.0.1", 2119, nil, 200, "active")
            checker:report_http_status("127.0.0.1", 2119, nil, 200, "active")
            checker:report_http_status("127.0.0.1", 2119, nil, 200, "active")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2119, nil))  -- false
        }
    }
--- request
GET /t
--- response_body
false
--- no_error_log
healthy SUCCESS increment
event: target status '127.0.0.1 (127.0.0.1:2119)' from 'false' to 'true'


=== TEST 5: report_http_status() with failure is a nop when passive.unhealthy.http_failures == 0
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2119;
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
                            interval = 999, -- we don't want active checks
                            successes = 4,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 4,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 0,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2119, nil, true)
            ngx.sleep(0.01)
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "passive")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2119))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- no_error_log
unhealthy HTTP increment
event: target status '127.0.0.1 (127.0.0.1:2119)' from 'true' to 'false'


=== TEST 4: report_http_status() with success is a nop when active.unhealthy.http_failures == 0
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2119;
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
                            interval = 999, -- we don't want active checks
                            successes = 4,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 2,
                            http_failures = 0,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 4,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2119, nil, true)
            ngx.sleep(0.01)
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "active")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "active")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "active")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "active")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2119, nil))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- no_error_log
unhealthy HTTP increment
event: target status '(127.0.0.1:2119)' from 'true' to 'false'


=== TEST 5: report_http_status() must work in log phase
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location = /t {
        content_by_lua_block {
            ngx.say("OK")
        }
        log_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
events_module = "resty.events",
                type = "http",
                checks = {
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2119, nil, true)
            ngx.sleep(0.01)
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "passive")
            ngx.sleep(0.01)
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "passive")
        }
    }
--- request
GET /t
--- response_body
OK
--- no_error_log
failed to acquire lock: API disabled in the context of log_by_lua
