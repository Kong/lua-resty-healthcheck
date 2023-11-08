use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * (blocks() * 3) + 1;

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

=== TEST 1: start() can start after stop()
--- http_config eval: $::HttpConfig
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
                        healthy  = {
                            interval = 0.1
                        },
                        unhealthy  = {
                            interval = 0.1
                        }
                    }
                }
            })
            local ok, err = checker:stop()
            ngx.sleep(0.2) -- wait twice the interval
            local ok, err = checker:start()
            ngx.say(ok)
        }
    }
--- request
GET /t
--- response_body
true
--- no_error_log
[error]


=== TEST 3: start() is a no-op if active intervals are 0
--- http_config eval: $::HttpConfig
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
                        healthy  = {
                            interval = 0
                        },
                        unhealthy  = {
                            interval = 0
                        }
                    }
                }
            })
            local ok, err = checker:start()
            ngx.say(ok)
            local ok, err = checker:start()
            ngx.say(ok)
            local ok, err = checker:start()
            ngx.say(ok)
        }
    }
--- request
GET /t
--- response_body
true
true
true
--- no_error_log
[error]

=== TEST 4: stop() stops health checks
--- http_config eval: $::HttpConfig
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
                        healthy  = {
                            interval = 0.1
                        },
                        unhealthy  = {
                            interval = 0.1
                        }
                    }
                }
            })
            local ok, err = checker:stop()
            ngx.say(ok)
        }
    }
--- request
GET /t
--- response_body
true
--- no_error_log
[error]
checking

=== TEST 5: start() restarts health checks
--- http_config eval: $::HttpConfig
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
                        healthy  = {
                            interval = 0.1
                        },
                        unhealthy  = {
                            interval = 0.1
                        }
                    }
                }
            })
            local ok, err = checker:stop()
            ngx.say(ok)
            ngx.sleep(1) -- active healthchecks might take up to 1s to start
            local ok, err = checker:start()
            ngx.say(ok)
            ngx.sleep(0.2) -- wait twice the interval
        }
    }
--- request
GET /t
--- response_body
true
true
--- error_log
checking
