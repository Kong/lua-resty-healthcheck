use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => blocks() * 2;

my $pwd = cwd();
my $ca_certs = '/etc/ssl/certs/ca-certificates.crt';
if (!-e $ca_certs) {
    # for centos or redhat
    $ca_certs = '/etc/ssl/certs/ca-bundle.trust.crt';
}

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;

    lua_ssl_trusted_certificate $ca_certs;
};

run_tests();

__DATA__

=== TEST 1: active probes, valid https
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        lua_ssl_verify_depth 2;
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
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
        lua_ssl_verify_depth 2;
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
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
        lua_ssl_verify_depth 2;
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
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
