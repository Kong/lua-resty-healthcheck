use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * (blocks() * 4) + 3;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__

=== TEST 1: add_target() adds an unhealthy target
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
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
            })
            ngx.sleep(1) -- active healthchecks might take up to 1s to start
            local ok, err = checker:add_target("127.0.0.1", 11111, nil, false)
            ngx.say(ok)
            ngx.sleep(0.5)
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: #1

--- no_error_log
checking healthy targets: #1



=== TEST 2: add_target() adds a healthy target
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2112;
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
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1
                        },
                        unhealthy  = {
                            interval = 0.1
                        }
                    }
                }
            })
            ngx.sleep(1) -- active healthchecks might take up to 1s to start
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            ngx.say(ok)
            ngx.sleep(0.2) -- wait twice the interval
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking unhealthy targets: nothing to do
checking healthy targets: #1

--- no_error_log
checking unhealthy targets: #1



=== TEST 3: calling add_target() repeatedly does not change status
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2113;
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
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1,
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            tcp_failures = 1,
                            http_failures = 1,
                        }
                    }
                }
            })
            ngx.sleep(1) -- active healthchecks might take up to 1s to start
            local ok, err = checker:add_target("127.0.0.1", 2113, nil, true)
            local ok, err = checker:add_target("127.0.0.1", 2113, nil, false)
            ngx.say(ok)
            ngx.sleep(0.2) -- wait twice the interval
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking unhealthy targets: nothing to do
checking healthy targets: #1

--- no_error_log
checking unhealthy targets: #1
