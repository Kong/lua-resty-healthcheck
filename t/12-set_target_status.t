use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 2;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__

=== TEST 1: set_target_status() updates a status
--- http_config eval
qq{
    $::HttpConfig
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
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- true
            checker:set_target_status("127.0.0.1", 2112, nil, false)
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- false
            checker:set_target_status("127.0.0.1", 2112, nil, true)
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- true
        }
    }
--- request
GET /t
--- response_body
true
false
true



=== TEST 2: set_target_status() restores node after passive check disables it
--- http_config eval
qq{
    $::HttpConfig
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
                    passive = {
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 2,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- true
            checker:report_http_status("127.0.0.1", 2112, nil, 500)
            checker:report_http_status("127.0.0.1", 2112, nil, 500)
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- false
            checker:set_target_status("127.0.0.1", 2112, nil, true)
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- true
        }
    }
--- request
GET /t
--- response_body
true
false
true



=== TEST 3: set_target_status() resets the failure counters
--- http_config eval
qq{
    $::HttpConfig
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
                    passive = {
                        healthy = {
                            successes = 2,
                        },
                        unhealthy = {
                            tcp_failures = 2,
                            http_failures = 2,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- true
            checker:report_http_status("127.0.0.1", 2112, nil, 500)
            checker:set_target_status("127.0.0.1", 2112, nil, true)
            checker:report_http_status("127.0.0.1", 2112, nil, 500)
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- true
            checker:report_http_status("127.0.0.1", 2112, nil, 500)
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- false
        }
    }
--- request
GET /t
--- response_body
true
true
false



=== TEST 4: set_target_status() resets the success counters
--- http_config eval
qq{
    $::HttpConfig
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
                    passive = {
                        healthy = {
                            successes = 2,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 2,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            checker:set_target_status("127.0.0.1", 2112, nil, false)
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- false
            checker:report_http_status("127.0.0.1", 2112, nil, 200)
            checker:set_target_status("127.0.0.1", 2112, nil, false)
            checker:report_http_status("127.0.0.1", 2112, nil, 200)
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- false
            checker:report_http_status("127.0.0.1", 2112, nil, 200)
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- true
        }
    }
--- request
GET /t
--- response_body
false
false
true
