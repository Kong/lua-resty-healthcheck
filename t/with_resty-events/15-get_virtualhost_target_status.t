use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * (blocks() * 5) + 2;

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

=== TEST 1: get_target_status() reports proper status for virtualhosts
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
events_module = "resty.events",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 999, -- we don't want active checks
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 1,
                            http_failures = 1,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 1,
                        },
                        unhealthy  = {
                            tcp_failures = 1,
                            http_failures = 2,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2115, "ahostname", true)
            local ok, err = checker:add_target("127.0.0.1", 2115, "otherhostname", true)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "ahostname"))  -- true
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "otherhostname"))  -- true
            checker:report_http_status("127.0.0.1", 2115, "otherhostname", 500, "passive")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "otherhostname"))  -- true
            checker:report_http_status("127.0.0.1", 2115, "otherhostname", 500, "passive")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "otherhostname"))  -- false
            checker:report_success("127.0.0.1", 2115, "otherhostname")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "otherhostname"))  -- true
            checker:report_tcp_failure("127.0.0.1", 2115, "otherhostname")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "otherhostname"))  -- false
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "ahostname"))  -- true
            local _, err = checker:get_target_status("127.0.0.1", 2115)
            ngx.say(err)  -- target not found
        }
    }
--- request
GET /t
--- response_body
true
true
true
false
true
false
true
target not found
--- error_log
unhealthy HTTP increment (1/2) for 'otherhostname(127.0.0.1:2115)'
unhealthy HTTP increment (2/2) for 'otherhostname(127.0.0.1:2115)'
event: target status 'otherhostname(127.0.0.1:2115)' from 'true' to 'false'



=== TEST 2: get_target_status() reports proper status for mixed targets (with/without hostname)
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
events_module = "resty.events",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 999, -- we don't want active checks
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 1,
                            http_failures = 1,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 1,
                        },
                        unhealthy  = {
                            tcp_failures = 1,
                            http_failures = 1,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2116, "ahostname", true)
            local ok, err = checker:add_target("127.0.0.1", 2116, nil, true)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2116, "ahostname"))  -- true
            ngx.say(checker:get_target_status("127.0.0.1", 2116))  -- true
            checker:report_http_status("127.0.0.1", 2116, nil, 500, "passive")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2116, "ahostname"))  -- true
            ngx.say(checker:get_target_status("127.0.0.1", 2116)) -- false
        }
    }
--- request
GET /t
--- response_body
true
true
true
false
--- error_log
unhealthy HTTP increment (1/1) for '(127.0.0.1:2116)'
event: target status '(127.0.0.1:2116)' from 'true' to 'false'



=== TEST 3: active probe for virtualhosts listening on same port:ip combination
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2117;
        server_name healthyserver;
        location = /status {
            return 200;
        }
    }
    server {
        listen 2117;
        server_name unhealthyserver;
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
            local ok, err = checker:add_target("127.0.0.1", 2117, "healthyserver", true)
            local ok, err = checker:add_target("127.0.0.1", 2117, "unhealthyserver", true)
            ngx.sleep(0.6) -- wait for 6x the check interval
            ngx.say(checker:get_target_status("127.0.0.1", 2117, "healthyserver"))  -- true
            ngx.say(checker:get_target_status("127.0.0.1", 2117, "unhealthyserver"))  -- false
            local _, err = checker:get_target_status("127.0.0.1", 2117)
            ngx.say(err)  -- target not found
        }
    }
--- request
GET /t
--- response_body
true
false
target not found
--- error_log
checking unhealthy targets: nothing to do
unhealthy HTTP increment (1/3) for 'unhealthyserver(127.0.0.1:2117)'
unhealthy HTTP increment (2/3) for 'unhealthyserver(127.0.0.1:2117)'
unhealthy HTTP increment (3/3) for 'unhealthyserver(127.0.0.1:2117)'
event: target status 'unhealthyserver(127.0.0.1:2117)' from 'true' to 'false'



=== TEST 4: get_target_status() reports proper status for same target with and without hostname
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
events_module = "resty.events",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 999, -- we don't want active checks
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 1,
                            http_failures = 1,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 1,
                        },
                        unhealthy  = {
                            tcp_failures = 1,
                            http_failures = 1,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2118, "127.0.0.1", true)
            local ok, err = checker:add_target("127.0.0.1", 2119, nil, true)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2118, "127.0.0.1"))  -- true
            ngx.say(checker:get_target_status("127.0.0.1", 2119))  -- true
            ngx.say(checker:get_target_status("127.0.0.1", 2118))  -- true
            ngx.say(checker:get_target_status("127.0.0.1", 2119, "127.0.0.1"))  -- true
            checker:report_http_status("127.0.0.1", 2118, nil, 500, "passive")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2118, "127.0.0.1"))  -- false
            ngx.say(checker:get_target_status("127.0.0.1", 2119))  -- true
            ngx.say(checker:get_target_status("127.0.0.1", 2118))  -- false
            ngx.say(checker:get_target_status("127.0.0.1", 2119, "127.0.0.1"))  -- true
            checker:report_http_status("127.0.0.1", 2119, "127.0.0.1", 500, "passive")
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2118, "127.0.0.1"))  -- false
            ngx.say(checker:get_target_status("127.0.0.1", 2119))  -- false
            ngx.say(checker:get_target_status("127.0.0.1", 2118))  -- false
            ngx.say(checker:get_target_status("127.0.0.1", 2119, "127.0.0.1"))  -- false
        }
    }
--- request
GET /t
--- response_body
true
true
true
true
false
true
false
true
false
false
false
false
--- error_log
unhealthy HTTP increment (1/1) for '(127.0.0.1:2118)'
event: target status '(127.0.0.1:2118)' from 'true' to 'false'
unhealthy HTTP increment (1/1) for '127.0.0.1(127.0.0.1:2119)'
event: target status '127.0.0.1(127.0.0.1:2119)' from 'true' to 'false'
