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



=== TEST 1: active probes, http node failing
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2130;
        location = /status {
            content_by_lua_block {
                ngx.sleep(2)
                ngx.exit(500);
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
                        timeout = 1,
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
            local ok, err = checker:add_target("127.0.0.1", 2130, nil, true)
            ngx.sleep(3) -- wait for some time to let the checks run
            -- There should be no more than 3 timers running atm, but
            -- add a few spaces for worker events
            ngx.say(tonumber(ngx.timer.running_count()) <= 5)
        }
    }
--- request
GET /t
--- response_body
true
