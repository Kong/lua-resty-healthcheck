use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * 2;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__



=== TEST 1: ensure counters work properly
--- http_config eval
qq{
    $::HttpConfig
}
--- config eval
qq{
    location = /t {
        content_by_lua_block {
            local host = "127.0.0.1"
            local port = 2112

            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                test = true,
                name = "testing",
                shm_name = "test_shm",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0,
                            successes = 4,
                        },
                        unhealthy  = {
                            interval = 0,
                            tcp_failures = 2,
                            http_failures = 0,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 2,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 2,
                            timeouts = 2,
                        }
                    }
                }
            })

            local ok, err = checker:add_target(host, port, nil, true)

            we.poll()

            -- S = successes counter
            -- F = http_failures counter
            -- T = tcp_failures counter
            -- O = timeouts counter

            local cases = {}

            local function incr(idxs, i, max)
               idxs[i] = idxs[i] + 1
               if idxs[i] > max and i > 1 then
                  idxs[i] = 1
                  incr(idxs, i - 1, max)
               end
            end

            local function add_cases(cases, len, m)
               local idxs = {}
               for i = 1, len do
                  idxs[i] = 1
               end
               local word = {}
               for _ = 1, (#m) ^ len do
                  for c = 1, len do
                     word[c] = m[idxs[c]]
                  end
                  table.insert(cases, table.concat(word))
                  incr(idxs, len, #m)
               end
            end

            local m = { "S", "F", "T", "O" }

            -- There are 324 (3*3*3*3*4) possible internal states
            -- to the above healthcheck configuration where all limits are set to 2.
            -- We need at least five events (4*4*4*4) to be able
            -- to exercise all of them
            for i = 1, 5 do
               add_cases(cases, i, m)
            end

            -- Brute-force test all combinations of health events up to 5 events
            -- and compares the results given by the library with a simple simulation
            -- that implements the specified behavior.
            local function run_test_case(case)
                assert(checker:set_target_status(host, port, nil, true))

                we.poll()

                local i = 1
                local s, f, t, o = 0, 0, 0, 0
                local mode = true
                for c in case:gmatch(".") do
                    if c == "S" then
                        checker:report_http_status(host, port, nil, 200, "passive")
                        s = s + 1
                        f, t, o = 0, 0, 0
                        if s == 2 then
                            mode = true
                        end
                    elseif c == "F" then
                        checker:report_http_status(host, port, nil, 500, "passive")
                        f = f + 1
                        s = 0
                        if f == 2 then
                            mode = false
                        end
                    elseif c == "T" then
                        checker:report_tcp_failure(host, port, nil, "read", "passive")
                        t = t + 1
                        s = 0
                        if t == 2 then
                            mode = false
                        end
                    elseif c == "O" then
                        checker:report_timeout(host, port, nil, "passive")
                        o = o + 1
                        s = 0
                        if o == 2 then
                            mode = false
                        end
                    end

                    --local ctr, state = checker:test_get_counter(host, port, nil)
                    --ngx.say(case, ": ", c, " ", string.format("%08x", ctr), " ", state)
                    --ngx.log(ngx.DEBUG, case, ": ", c, " ", string.format("%08x", ctr), " ", state)

                    we.poll()

                    if checker:get_target_status(host, port, nil) ~= mode then
                        ngx.say("failed: ", case, " step ", i, " expected ", mode)
                        return false
                    end
                    i = i + 1
                end
                return true
            end

            for _, case in ipairs(cases) do
                ngx.log(ngx.ERR, "Case: ", case)
                run_test_case(case)
            end
            ngx.say("all ok!")
        }
    }
}
--- request
GET /t
--- response_body
all ok!
--- error_log
--- no_error_log
