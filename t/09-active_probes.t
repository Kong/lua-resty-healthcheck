use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * 56;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__



=== TEST 1: active probes, http node failing
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
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, true)
            we.poll()
            ngx.sleep(0.5) -- wait for 5x the check interval
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- false
        }
    }
--- request
GET /t
--- response_body
false
--- error_log
checking unhealthy targets: nothing to do
unhealthy HTTP increment (1/3) for '(127.0.0.1:2114)'
unhealthy HTTP increment (2/3) for '(127.0.0.1:2114)'
unhealthy HTTP increment (3/3) for '(127.0.0.1:2114)'
event: target status '(127.0.0.1:2114)' from 'true' to 'false'
checking healthy targets: nothing to do



=== TEST 2: active probes, http node recovering
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
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, false)
            we.poll()
            ngx.sleep(0.5) -- wait for 5x the check interval
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking healthy targets: nothing to do
healthy SUCCESS increment (1/3) for '(127.0.0.1:2114)'
healthy SUCCESS increment (2/3) for '(127.0.0.1:2114)'
healthy SUCCESS increment (3/3) for '(127.0.0.1:2114)'
event: target status '(127.0.0.1:2114)' from 'false' to 'true'
checking unhealthy targets: nothing to do

=== TEST 3: active probes, custom http status (regression test for pre-filled defaults)
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
                            interval = 0.1,
                            successes = 3,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 3,
                            http_statuses = { 429 },
                        }
                    },
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, true)
            we.poll()
            ngx.sleep(0.5) -- wait for 5x the check interval
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking unhealthy targets: nothing to do
--- no_error_log
checking healthy targets: nothing to do
unhealthy HTTP increment (1/3) for '(127.0.0.1:2114)'
unhealthy HTTP increment (2/3) for '(127.0.0.1:2114)'
unhealthy HTTP increment (3/3) for '(127.0.0.1:2114)'
event: target status '(127.0.0.1:2114)' from 'true' to 'false'


=== TEST 4: active probes, custom http status, node failing
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2114;
        location = /status {
            return 401;
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
                            interval = 0.1,
                            successes = 3,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 3,
                            http_statuses = { 401 },
                        }
                    },
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, true)
            we.poll()
            ngx.sleep(0.5) -- wait for 5x the check interval
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- false
        }
    }
--- request
GET /t
--- response_body
false
--- error_log
checking unhealthy targets: nothing to do
unhealthy HTTP increment (1/3) for '(127.0.0.1:2114)'
unhealthy HTTP increment (2/3) for '(127.0.0.1:2114)'
unhealthy HTTP increment (3/3) for '(127.0.0.1:2114)'
event: target status '(127.0.0.1:2114)' from 'true' to 'false'
checking healthy targets: nothing to do



=== TEST 5: active probes, host is correctly set
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2114;
        location = /status {
            content_by_lua_block {
                if ngx.req.get_headers()["Host"] == "example.com" then
                    ngx.exit(200)
                else
                    ngx.exit(500)
                end
            }
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
                            interval = 0.1,
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 1,
                        }
                    },
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2114, "example.com", false)
            we.poll()
            ngx.sleep(0.3) -- wait for 3x the check interval
            ngx.say(checker:get_target_status("127.0.0.1", 2114, "example.com"))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
event: target status 'example.com(127.0.0.1:2114)' from 'false' to 'true'
checking unhealthy targets: nothing to do


=== TEST 6: active probes, tcp node failing
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
                type = "tcp",
                checks = {
                    active = {
                        healthy  = {
                            interval = 0.1,
                            successes = 3,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            tcp_failures = 3,
                        }
                    },
                }
            })
            -- Note: no http server configured, so port 2114 remains unanswered
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, true)
            we.poll()
            ngx.sleep(0.5) -- wait for 5x the check interval
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- false
        }
    }
--- request
GET /t
--- response_body
false
--- error_log
checking unhealthy targets: nothing to do
unhealthy TCP increment (1/3) for '(127.0.0.1:2114)'
unhealthy TCP increment (2/3) for '(127.0.0.1:2114)'
unhealthy TCP increment (3/3) for '(127.0.0.1:2114)'
event: target status '(127.0.0.1:2114)' from 'true' to 'false'
checking healthy targets: nothing to do



=== TEST 7: active probes, tcp node recovering
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
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                type = "tcp",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1,
                            successes = 3,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            tcp_failures = 3,
                        }
                    },
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2114, nil, false)
            we.poll()
            ngx.sleep(0.5) -- wait for 5x the check interval
            ngx.say(checker:get_target_status("127.0.0.1", 2114))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking healthy targets: nothing to do
healthy SUCCESS increment (1/3) for '(127.0.0.1:2114)'
healthy SUCCESS increment (2/3) for '(127.0.0.1:2114)'
healthy SUCCESS increment (3/3) for '(127.0.0.1:2114)'
event: target status '(127.0.0.1:2114)' from 'false' to 'true'
checking unhealthy targets: nothing to do



=== TEST 8: active probes, custom Host header is correctly set
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2114;
        location = /status {
            content_by_lua_block {
                if ngx.req.get_headers()["Host"] == "custom-host.test" then
                    ngx.exit(200)
                else
                    ngx.exit(500)
                end
            }
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
                            interval = 0.1,
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 1,
                        }
                    },
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2114, "example.com", false, "custom-host.test")
            we.poll()
            ngx.sleep(0.3) -- wait for 3x the check interval
            ngx.say(checker:get_target_status("127.0.0.1", 2114, "example.com"))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
event: target status 'example.com(127.0.0.1:2114)' from 'false' to 'true'
checking unhealthy targets: nothing to do


