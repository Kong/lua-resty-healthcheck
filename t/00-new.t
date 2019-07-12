use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * (blocks() * 3) - 2;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__

=== TEST 1: new() requires worker_events to be configured
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local ok, err = pcall(healthcheck.new)
            ngx.log(ngx.ERR, err)
        }
    }
--- request
GET /t
--- response_body

--- error_log
please configure



=== TEST 2: new() requires 'name'
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local ok, err = pcall(healthcheck.new, {
                shm_name = "test_shm",
            })
            ngx.log(ngx.ERR, err)
        }
    }
--- request
GET /t
--- response_body

--- error_log
required option 'name' is missing



=== TEST 3: new() requires 'shm_name'
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local ok, err = pcall(healthcheck.new, {
                name = "testing",
            })
            ngx.log(ngx.ERR, err)
        }
    }
--- request
GET /t
--- response_body

--- error_log
required option 'shm_name' is missing



=== TEST 4: new() fails with invalid shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local ok, err = pcall(healthcheck.new, {
                name = "testing",
                shm_name = "invalid_shm",
            })
            ngx.log(ngx.ERR, err)
        }
    }
--- request
GET /t
--- response_body

--- error_log
no shm found by name



=== TEST 5: new() initializes with default config
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local ok, err = pcall(healthcheck.new, {
                name = "testing",
                shm_name = "test_shm",
            })
        }
    }
--- request
GET /t
--- response_body

--- error_log
Healthchecker started!



=== TEST 6: new() only accepts http or tcp types
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local ok, err = pcall(healthcheck.new, {
                name = "testing",
                shm_name = "test_shm",
                type = "http",
            })
            ngx.say(ok)
            local ok, err = pcall(healthcheck.new, {
                name = "testing",
                shm_name = "test_shm",
                type = "tcp",
            })
            ngx.say(ok)
            local ok, err = pcall(healthcheck.new, {
                name = "testing",
                shm_name = "test_shm",
                type = "get lost",
            })
            ngx.say(ok)
        }
    }
--- request
GET /t
--- response_body
true
true
false



=== TEST 7: new() deals with bad inputs
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")

            -- tests for failure
            local tests = {
                { active = { timeout = -1 }},
                { active = { timeout = 1e+42 }},
                { active = { concurrency = -1 }},
                { active = { concurrency = 1e42 }},
                { active = { healthy = { interval = -1 }}},
                { active = { healthy = { interval = 1e42 }}},
                { active = { healthy = { successes = -1 }}},
                { active = { healthy = { successes = 1e42 }}},
                { active = { unhealthy = { interval = -1 }}},
                { active = { unhealthy = { interval = 1e42 }}},
                { active = { unhealthy = { tcp_failures = -1 }}},
                { active = { unhealthy = { tcp_failures = 1e42 }}},
                { active = { unhealthy = { timeouts = -1 }}},
                { active = { unhealthy = { timeouts = 1e42 }}},
                { active = { unhealthy = { http_failures = -1 }}},
                { active = { unhealthy = { http_failures = 1e42 }}},
                { passive = { healthy = { successes = -1 }}},
                { passive = { healthy = { successes = 1e42 }}},
                { passive = { unhealthy = { tcp_failures = -1 }}},
                { passive = { unhealthy = { tcp_failures = 1e42 }}},
                { passive = { unhealthy = { timeouts = -1 }}},
                { passive = { unhealthy = { timeouts = 1e42 }}},
                { passive = { unhealthy = { http_failures = -1 }}},
                { passive = { unhealthy = { http_failures = 1e42 }}},
            }
            for _, test in ipairs(tests) do
                local ok, err = pcall(healthcheck.new, {
                    name = "testing",
                    shm_name = "test_shm",
                    type = "http",
                    checks = test,
                })
                ngx.say(ok)
            end
        }
    }
--- request
GET /t
--- response_body
false
false
false
false
false
false
false
false
false
false
false
false
false
false
false
false
false
false
false
false
false
false
false
false
