use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * 32;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__



=== TEST 1: report_success() recovers HTTP active + passive
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2116;
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
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 3,
                            http_failures = 3,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2116, nil, false)
            local ok, err = checker:add_target("127.0.0.1", 2118, nil, false)
            we.poll()
            checker:report_success("127.0.0.1", 2116, nil, "active")
            checker:report_success("127.0.0.1", 2118, nil, "passive")
            checker:report_success("127.0.0.1", 2116, nil, "active")
            checker:report_success("127.0.0.1", 2118, nil, "passive")
            checker:report_success("127.0.0.1", 2116, nil, "active")
            checker:report_success("127.0.0.1", 2118, nil, "passive")
            we.poll()
            ngx.say(checker:get_target_status("127.0.0.1", 2116))  -- true
            ngx.say(checker:get_target_status("127.0.0.1", 2118))  -- true
        }
    }
--- request
GET /t
--- response_body
true
true
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: nothing to do
healthy SUCCESS increment (1/3) for '(127.0.0.1:2116)'
healthy SUCCESS increment (2/3) for '(127.0.0.1:2116)'
healthy SUCCESS increment (3/3) for '(127.0.0.1:2116)'
event: target status '(127.0.0.1:2116)' from 'false' to 'true'
healthy SUCCESS increment (1/3) for '(127.0.0.1:2116)'
healthy SUCCESS increment (2/3) for '(127.0.0.1:2116)'
healthy SUCCESS increment (3/3) for '(127.0.0.1:2116)'
event: target status '(127.0.0.1:2118)' from 'false' to 'true'


=== TEST 2: report_success() recovers TCP active = passive
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2116;
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
                            interval = 999, -- we don't want active checks
                            successes = 3,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 3,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 3,
                            http_failures = 3,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2116, nil, false)
            local ok, err = checker:add_target("127.0.0.1", 2118, nil, false)
            we.poll()
            checker:report_success("127.0.0.1", 2116, nil, "active")
            checker:report_success("127.0.0.1", 2118, nil, "passive")
            checker:report_success("127.0.0.1", 2116, nil, "active")
            checker:report_success("127.0.0.1", 2118, nil, "passive")
            checker:report_success("127.0.0.1", 2116, nil, "active")
            checker:report_success("127.0.0.1", 2118, nil, "passive")
            we.poll()
            ngx.say(checker:get_target_status("127.0.0.1", 2116))  -- true
            ngx.say(checker:get_target_status("127.0.0.1", 2118))  -- true
        }
    }
--- request
GET /t
--- response_body
true
true
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: nothing to do
healthy SUCCESS increment (1/3) for '(127.0.0.1:2116)'
healthy SUCCESS increment (2/3) for '(127.0.0.1:2116)'
healthy SUCCESS increment (3/3) for '(127.0.0.1:2116)'
event: target status '(127.0.0.1:2116)' from 'false' to 'true'
healthy SUCCESS increment (1/3) for '(127.0.0.1:2116)'
healthy SUCCESS increment (2/3) for '(127.0.0.1:2116)'
healthy SUCCESS increment (3/3) for '(127.0.0.1:2116)'
event: target status '(127.0.0.1:2118)' from 'false' to 'true'

=== TEST 3: report_success() is a nop when active.healthy.sucesses == 0
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2116;
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
                            interval = 999, -- we don't want active checks
                            successes = 0,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 3,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 3,
                            http_failures = 3,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2116, nil, false)
            we.poll()
            checker:report_success("127.0.0.1", 2116, nil, "active")
            checker:report_success("127.0.0.1", 2116, nil, "active")
            checker:report_success("127.0.0.1", 2116, nil, "active")
            we.poll()
            ngx.say(checker:get_target_status("127.0.0.1", 2116))  -- false
        }
    }
--- request
GET /t
--- response_body
false
--- no_error_log
healthy SUCCESS increment
event: target status '127.0.0.1 (127.0.0.1:2116)' from 'false' to 'true'



=== TEST 4: report_success() is a nop when passive.healthy.sucesses == 0
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2118;
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
                            interval = 0, -- we don't want active checks
                            successes = 0,
                        },
                        unhealthy  = {
                            interval = 0, -- we don't want active checks
                            tcp_failures = 3,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 0,
                        },
                        unhealthy  = {
                            tcp_failures = 3,
                            http_failures = 3,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2118, nil, false)
            we.poll()
            checker:report_success("127.0.0.1", 2118, nil, "passive")
            checker:report_success("127.0.0.1", 2118, nil, "passive")
            checker:report_success("127.0.0.1", 2118, nil, "passive")
            we.poll()
            ngx.say(checker:get_target_status("127.0.0.1", 2118, nil))  -- false
        }
    }
--- request
GET /t
--- response_body
false
--- no_error_log
healthy SUCCESS increment
event: target status '(127.0.0.1:2118)' from 'false' to 'true'
