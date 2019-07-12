use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * 24;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__

=== TEST 1: report_tcp_failure() active + passive
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2120;
        location = /status {
            return 200;
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
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
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 3,
                            http_failures = 5,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2120, nil, true)
            local ok, err = checker:add_target("127.0.0.1", 2113, nil, true)
            checker:report_tcp_failure("127.0.0.1", 2120, nil, nil, "active")
            checker:report_tcp_failure("127.0.0.1", 2113, nil, nil, "passive")
            checker:report_tcp_failure("127.0.0.1", 2120, nil, nil, "active")
            checker:report_tcp_failure("127.0.0.1", 2113, nil, nil, "passive")
            checker:report_tcp_failure("127.0.0.1", 2120, nil, nil, "active")
            checker:report_tcp_failure("127.0.0.1", 2113, nil, nil, "passive")
            ngx.say(checker:get_target_status("127.0.0.1", 2120))  -- false
            ngx.say(checker:get_target_status("127.0.0.1", 2113))  -- false
        }
    }
--- request
GET /t
--- response_body
false
false
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: nothing to do
unhealthy TCP increment (1/3) for '(127.0.0.1:2120)'
unhealthy TCP increment (2/3) for '(127.0.0.1:2120)'
unhealthy TCP increment (3/3) for '(127.0.0.1:2120)'
event: target status '(127.0.0.1:2120)' from 'true' to 'false'
unhealthy TCP increment (1/3) for '(127.0.0.1:2113)'
unhealthy TCP increment (2/3) for '(127.0.0.1:2113)'
unhealthy TCP increment (3/3) for '(127.0.0.1:2113)'
event: target status '(127.0.0.1:2113)' from 'true' to 'false'



=== TEST 2: report_tcp_failure() for active is a nop when active.unhealthy.tcp_failures == 0
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2120;
        location = /status {
            return 200;
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
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
                            tcp_failures = 0,
                            http_failures = 5,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 3,
                            http_failures = 5,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2120, nil, true)
            checker:report_tcp_failure("127.0.0.1", 2120, nil, nil, "active")
            checker:report_tcp_failure("127.0.0.1", 2120, nil, nil, "active")
            checker:report_tcp_failure("127.0.0.1", 2120, nil, nil, "active")
            ngx.say(checker:get_target_status("127.0.0.1", 2120))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: nothing to do
--- no_error_log
unhealthy TCP increment
event: target status '(127.0.0.1:2120)' from 'true' to 'false'



=== TEST 3: report_tcp_failure() for passive is a nop when passive.unhealthy.tcp_failures == 0
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2120;
        location = /status {
            return 200;
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
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
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 0,
                            http_failures = 5,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2120, nil, true)
            checker:report_tcp_failure("127.0.0.1", 2120, nil, nil, "passive")
            checker:report_tcp_failure("127.0.0.1", 2120, nil, nil, "passive")
            checker:report_tcp_failure("127.0.0.1", 2120, nil, nil, "passive")
            ngx.say(checker:get_target_status("127.0.0.1", 2120))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: nothing to do
--- no_error_log
unhealthy TCP increment
event: target status '(127.0.0.1:2120)' from 'true' to 'false'
