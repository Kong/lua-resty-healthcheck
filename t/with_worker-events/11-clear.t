use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * 27 + 2;

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
            ngx.sleep(1)
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
            ngx.sleep(0.5) -- wait 2.5x the interval
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
unhealthy HTTP increment (1/3) for '127.0.0.1(127.0.0.1:21120)'
unhealthy HTTP increment (2/3) for '127.0.0.1(127.0.0.1:21120)'
--- no_error_log
unhealthy HTTP increment (3/3) for '(127.0.0.1:21120)'


=== TEST 4: delayed_clear() clears the list, after interval new checkers don't see it
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
            ngx.say(checker1:get_target_status("127.0.0.1", 10001))
            checker1:delayed_clear(0.2)

            local checker2 = healthcheck.new(config)
            ngx.say(checker2:get_target_status("127.0.0.1", 10001))
            ngx.sleep(2.6) -- wait while the targets are cleared
            local status, err = checker2:get_target_status("127.0.0.1", 10001)
            if status ~= nil then
                ngx.say(status)
            else
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
false
false
target not found

=== TEST 5: delayed_clear() would clear tgt list, but adding again keeps the previous status
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
            checker1:add_target("127.0.0.1", 10001, nil, false)
            checker1:add_target("127.0.0.1", 10002, nil, false)
            checker1:add_target("127.0.0.1", 10003, nil, false)
            ngx.sleep(0.2) -- wait twice the interval
            ngx.say(checker1:get_target_status("127.0.0.1", 10002))
            checker1:delayed_clear(0.2)

            local checker2 = healthcheck.new(config)
            checker2:add_target("127.0.0.1", 10002, nil, true)
            ngx.say(checker2:get_target_status("127.0.0.1", 10002))
            ngx.sleep(2.6) -- wait while the targets would be cleared
            local status, err = checker2:get_target_status("127.0.0.1", 10001)
            if status ~= nil then
                ngx.say(status)
            else
                ngx.say(err)
            end
            status, err = checker2:get_target_status("127.0.0.1", 10002)
            if status ~= nil then
                ngx.say(status)
            else
                ngx.say(err)
            end
            status, err = checker2:get_target_status("127.0.0.1", 10003)
            if status ~= nil then
                ngx.say(status)
            else
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
false
false
target not found
false
target not found


=== TEST 6: delayed_clear() would clear tgt list when we add two checkers
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local config1 = {
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

            local config2 = {
                name = "testing2",
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

            local checker1 = healthcheck.new(config1)
            checker1:add_target("127.0.0.1", 10001, nil, true)
            checker1:add_target("127.0.0.1", 10002, nil, true)
            checker1:add_target("127.0.0.1", 10003, nil, true)
            ngx.say(checker1:get_target_status("127.0.0.1", 10002))
            checker1:delayed_clear(0.2)

            local checker2 = healthcheck.new(config2)
            checker2:add_target("127.0.0.1", 10001, nil, true)
            checker2:add_target("127.0.0.1", 10002, nil, true)
            ngx.say(checker2:get_target_status("127.0.0.1", 10002))
            checker2:delayed_clear(0.2)

            ngx.sleep(3) -- wait twice the interval

            local status, err = checker1:get_target_status("127.0.0.1", 10001)
            if status ~= nil then
                ngx.say(status)
            else
                ngx.say(err)
            end
            status, err = checker2:get_target_status("127.0.0.1", 10002)
            if status ~= nil then
                ngx.say(status)
            else
                ngx.say(err)
            end
            status, err = checker2:get_target_status("127.0.0.1", 10003)
            if status ~= nil then
                ngx.say(status)
            else
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
true
true
target not found
target not found
target not found
