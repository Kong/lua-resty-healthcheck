use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__



=== TEST 1: garbage collect the checker object
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2121;
        location = /status {
            return 200;
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            ngx.shared.my_worker_events:flush_all()
            local dump = function(...) ngx.log(ngx.DEBUG,"\027[31m\n", require("pl.pretty").write({...}),"\027[0m") end
            local we = require "resty.worker.events"
            assert(we.configure {
                shm = "my_worker_events",
                interval = 0.1,
                debug = true,
            })
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
            assert(checker:add_target("127.0.0.1", 2121, nil, true))
            local weak_table = setmetatable({ checker },{
              __mode = "v",
            })
            checker = nil   -- now only anchored in weak table above
            collectgarbage()
            collectgarbage()
            collectgarbage()
            collectgarbage()
            ngx.sleep(0.5)  -- leave room for timers to run (they shouldn't, but we want to be sure)
            ngx.say(#weak_table)  -- after GC, should be 0 length
        }
    }
--- request
GET /t
--- response_body
0
--- no_error_log
checking healthy targets: #1
