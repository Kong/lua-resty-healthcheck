use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * 23;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__

=== TEST 1: clear() clears the list, new checkers never see it
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local config = {
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy  = {
                            interval = 0.1
                        },
                        unhealthy  = {
                            interval = 0.1
                        }
                    }
                }
            }
            local checker1 = healthcheck.new(config)
            for i = 1, 10 do
                checker1:add_target("127.0.0.1", 10000 + i, nil, false)
            end
            ngx.sleep(0.2) -- wait twice the interval
            checker1:clear()

            local checker2 = healthcheck.new(config)

            ngx.say(true)
        }
    }
--- request
GET /t
--- response_body
true

--- error_log
initial target list (0 targets)

--- no_error_log
initial target list (1 targets)
initial target list (2 targets)
initial target list (3 targets)
initial target list (4 targets)
initial target list (5 targets)
initial target list (6 targets)
initial target list (7 targets)
initial target list (8 targets)
initial target list (9 targets)
initial target list (10 targets)
initial target list (11 targets)



=== TEST 2: clear() clears the list, other checkers get notified and clear too
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local config = {
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy  = {
                            interval = 0.1
                        },
                        unhealthy  = {
                            interval = 0.1
                        }
                    }
                }
            }
            local checker1 = healthcheck.new(config)
            local checker2 = healthcheck.new(config)
            for i = 1, 10 do
                checker1:add_target("127.0.0.1", 20000 + i, nil, false)
            end
            checker2:clear()
            ngx.sleep(0.2) -- wait twice the interval
            ngx.say(true)
        }
    }
--- request
GET /t
--- response_body
true

--- error_log
checking unhealthy targets: nothing to do

--- no_error_log
checking unhealthy targets: #10



=== TEST 3: clear() resets counters
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 21120;
        location = /status {
            return 503;
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local config = {
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.2,
                        },
                        unhealthy  = {
                            interval = 0.2,
                            http_failures = 3,
                        }
                    }
                }
            }
            local checker1 = healthcheck.new(config)
            checker1:add_target("127.0.0.1", 21120, nil, true)
            ngx.sleep(0.3) -- wait 1.5x the interval
            checker1:clear()
            checker1:add_target("127.0.0.1", 21120, nil, true)
            ngx.sleep(0.3) -- wait 1.5x the interval
            ngx.say(true)
        }
    }
--- request
GET /t
--- response_body
true

--- error_log
unhealthy HTTP increment (1/3) for '(127.0.0.1:21120)'
unhealthy HTTP increment (2/3) for '(127.0.0.1:21120)'
--- no_error_log
unhealthy HTTP increment (3/3) for '(127.0.0.1:21120)'
