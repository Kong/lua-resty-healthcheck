use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * 4;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__

=== TEST 1: configure a MTLS probe
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })

            local pl_file = require "pl.file"
            local cert = pl_file.read("t/with_worker-events/util/cert.pem", true)
            local key = pl_file.read("t/with_worker-events/util/key.pem", true)

            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing_mtls",
                shm_name = "test_shm",
                type = "http",
                ssl_cert = cert,
                ssl_key = key,
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
            ngx.say(checker ~= nil)  -- true
        }
    }
--- request
GET /t
--- response_body
true


=== TEST 2: configure a MTLS probe with parsed cert/key
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })

            local pl_file = require "pl.file"
            local ssl = require "ngx.ssl"
            local cert = ssl.parse_pem_cert(pl_file.read("t/with_worker-events/util/cert.pem", true))
            local key = ssl.parse_pem_priv_key(pl_file.read("t/with_worker-events/util/key.pem", true))

            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing_mtls",
                shm_name = "test_shm",
                type = "http",
                ssl_cert = cert,
                ssl_key = key,
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
            ngx.say(checker ~= nil)  -- true
        }
    }
--- request
GET /t
--- response_body
true
