use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(cwd);

workers(2);
master_on();

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;

    init_worker_by_lua_block {
        local we = require "resty.worker.events"
        assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
        ngx.timer.at(0, function()
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
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
            })
            local ok, err = checker:add_target("127.0.0.1", 11111)
            if not ok then
                error(err)
            end
        end)
    }
};

run_tests();

__DATA__

=== TEST 1: add_target() adds an unhealthy target
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            ngx.say(true)
            ngx.sleep(0.5) -- wait twice the interval
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking unhealthy targets: nothing to do
checking unhealthy targets: #1
