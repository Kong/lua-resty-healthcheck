use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * 16;

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



=== TEST 1: report_timeout() active + passive
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2122;
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
                            tcp_failures = 3,
                            http_failures = 5,
                            timeouts = 2,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 3,
                            http_failures = 5,
                            timeouts = 2,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2122, nil, true)
            local ok, err = checker:add_target("127.0.0.1", 2113, nil, true)
            ngx.sleep(0.01)
            checker:report_timeout("127.0.0.1", 2122, nil, "active")
            checker:report_timeout("127.0.0.1", 2113, nil, "passive")
            checker:report_timeout("127.0.0.1", 2122, nil, "active")
            checker:report_timeout("127.0.0.1", 2113, nil, "passive")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2122))  -- false
            ngx.say(checker:get_target_status("127.0.0.1", 2113))  -- false
        }
    }
--- request
GET /t
--- response_body
false
false
--- error_log
unhealthy TIMEOUT increment (1/2) for '(127.0.0.1:2122)'
unhealthy TIMEOUT increment (2/2) for '(127.0.0.1:2122)'
event: target status '(127.0.0.1:2122)' from 'true' to 'false'
unhealthy TIMEOUT increment (1/2) for '(127.0.0.1:2113)'
unhealthy TIMEOUT increment (2/2) for '(127.0.0.1:2113)'
event: target status '(127.0.0.1:2113)' from 'true' to 'false'


=== TEST 2: report_timeout() for active is a nop when active.unhealthy.timeouts == 0
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2122;
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
                            tcp_failures = 3,
                            http_failures = 5,
                            timeouts = 0,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 3,
                            http_failures = 5,
                            timeouts = 2,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2122, nil, true)
            ngx.sleep(0.01)
            checker:report_timeout("127.0.0.1", 2122, nil, "active")
            checker:report_timeout("127.0.0.1", 2122, nil, "active")
            checker:report_timeout("127.0.0.1", 2122, nil, "active")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2122))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- no_error_log
unhealthy TCP increment
event: target status '(127.0.0.1:2122)' from 'true' to 'false'



=== TEST 3: report_timeout() for passive is a nop when passive.unhealthy.timeouts == 0
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2122;
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
                            tcp_failures = 3,
                            http_failures = 5,
                            timeouts = 2,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 3,
                            http_failures = 5,
                            timeouts = 0,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2122, nil, true)
            ngx.sleep(0.01)
            checker:report_timeout("127.0.0.1", 2122, nil, "passive")
            checker:report_timeout("127.0.0.1", 2122, nil, "passive")
            checker:report_timeout("127.0.0.1", 2122, nil, "passive")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2122))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- no_error_log
unhealthy TCP increment
event: target status '(127.0.0.1:2122)' from 'true' to 'false'
