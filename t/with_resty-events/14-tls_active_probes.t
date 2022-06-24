use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => blocks() * 2;

my $pwd = cwd();
$ENV{TEST_NGINX_SERVROOT} = server_root();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;

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



=== TEST 1: active probes, valid https
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        lua_ssl_verify_depth 2;
        content_by_lua_block {
            local we = require "resty.events.compat"
            assert(we.configure({ unique_timeout = 5, broker_id = 0, listening = "unix:" .. ngx.config.prefix() .. "worker_events.sock" }))
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
events_module = "resty.events",
                checks = {
                    active = {
                        type = "https",
                        http_path = "/",
                        healthy  = {
                            interval = 2,
                            successes = 2,
                        },
                        unhealthy  = {
                            interval = 2,
                            tcp_failures = 2,
                        }
                    },
                }
            })
            local ok, err = checker:add_target("104.154.89.105", 443, "badssl.com", false)
            ngx.sleep(8) -- wait for 4x the check interval
            ngx.say(checker:get_target_status("104.154.89.105", 443, "badssl.com"))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- timeout
15

=== TEST 2: active probes, invalid cert
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        lua_ssl_verify_depth 2;
        content_by_lua_block {
            local we = require "resty.events.compat"
            assert(we.configure({ unique_timeout = 5, broker_id = 0, listening = "unix:" .. ngx.config.prefix() .. "worker_events.sock" }))
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
events_module = "resty.events",
                checks = {
                    active = {
                        type = "https",
                        http_path = "/",
                        healthy  = {
                            interval = 2,
                            successes = 2,
                        },
                        unhealthy  = {
                            interval = 2,
                            tcp_failures = 2,
                        }
                    },
                }
            })
            local ok, err = checker:add_target("104.154.89.105", 443, "wrong.host.badssl.com", true)
            ngx.sleep(8) -- wait for 4x the check interval
            ngx.say(checker:get_target_status("104.154.89.105", 443, "wrong.host.badssl.com"))  -- false
        }
    }
--- request
GET /t
--- response_body
false
--- timeout
15

=== TEST 3: active probes, accept invalid cert when disabling check
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        lua_ssl_verify_depth 2;
        content_by_lua_block {
            local we = require "resty.events.compat"
            assert(we.configure({ unique_timeout = 5, broker_id = 0, listening = "unix:" .. ngx.config.prefix() .. "worker_events.sock" }))
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
events_module = "resty.events",
                checks = {
                    active = {
                        type = "https",
                        https_verify_certificate = false,
                        http_path = "/",
                        healthy  = {
                            interval = 2,
                            successes = 2,
                        },
                        unhealthy  = {
                            interval = 2,
                            tcp_failures = 2,
                        }
                    },
                }
            })
            local ok, err = checker:add_target("104.154.89.105", 443, "wrong.host.badssl.com", false)
            ngx.sleep(8) -- wait for 4x the check interval
            ngx.say(checker:get_target_status("104.154.89.105", 443, "wrong.host.badssl.com"))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- timeout
15
