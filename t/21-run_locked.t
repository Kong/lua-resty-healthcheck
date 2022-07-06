use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * (blocks() * 3) + 1;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;

    init_worker_by_lua_block {
        local we = require "resty.worker.events"

        assert(we.configure{ shm = "my_worker_events", interval = 0.1 })

        _G.__TESTING_HEALTHCHECKER = true

        local healthcheck = require("resty.healthcheck")

        _G.checker = assert(healthcheck.new({
            name = "testing",
            shm_name = "test_shm",
            checks = {
                active = {
                    healthy  = {
                        interval = 0,
                    },
                    unhealthy  = {
                        interval = 0,
                    }
                }
            }
        }))

        checker._set_lock_timeout(1)
    }
};

run_tests();

__DATA__

=== TEST 1: run_locked() runs a function immediately and returns its result
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local checker = _G.checker

            local flag = false
            local ok, err = checker:_run_locked("key", function()
                flag = true
                return "OK"
            end)

            ngx.say(ok)
            ngx.say(err)
            ngx.say(flag)
        }
    }
--- request
GET /t
--- response_body
OK
nil
true
--- no_error_log
[error]



=== TEST 2: run_locked() can run a function immediately in an non-yieldable phase if no lock is held
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        set_by_lua_block $test {
            local checker = _G.checker
            local value
            local ok, err = checker:_run_locked("key", function()
                value = "SET"
                return "OK"
            end)

            if not ok then
                ngx.log(ngx.ERR, "run_locked failed: ", err)
                return
            end

            ngx.ctx.ok = ok
            return value
        }

        content_by_lua_block {
            ngx.say(ngx.ctx.ok)
            ngx.say(ngx.var.test)
        }
    }
--- request
GET /t
--- response_body
OK
SET
--- no_error_log
[error]



=== TEST 3: run_locked() schedules a function in a timer if a lock cannot be acquired during a non-yieldable phase
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        set_by_lua_block $test {
            local checker = _G.checker

            local key = "my_lock_key"

            local resty_lock = require "resty.lock"
            local lock = assert(resty_lock:new(checker.shm_name))
            assert(lock:lock(key))
            ngx.ctx.lock = lock

            local t = {}
            ngx.ctx.t = t

            local ok, err = checker:_run_locked(key, function()
                t.flag = true
                t.phase = ngx.get_phase()
                return true
            end)

            assert(err == nil, "expected no error")
            assert(ok == "scheduled", "expected the function to be scheduled")
        }

        content_by_lua_block {
            assert(ngx.ctx.lock:unlock())

            local t = ngx.ctx.t

            for i = 1, 10 do
                if t.flag then
                    break
                end
                ngx.sleep(0.25)
            end

            ngx.say(t.phase or "none")
            ngx.say(t.flag or "timeout")
        }
    }
--- request
GET /t
--- response_body
timer
true
--- no_error_log
[error]



=== TEST 4: run_locked() doesn't schedule a function in a timer during a yieldable phase
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local checker = _G.checker

            local key = "my_lock_key"

            local resty_lock = require "resty.lock"
            local lock = assert(resty_lock:new(checker.shm_name))
            assert(lock:lock(key))

            local flag = false
            local ok, err = checker:_run_locked(key, function()
                flag = true
                return true
            end)

            ngx.say(ok)
            ngx.say(err)
            ngx.say(flag)
        }
    }
--- request
GET /t
--- response_body
nil
failed acquiring lock for 'my_lock_key', timeout
false
--- no_error_log
[error]



=== TEST 5: run_locked() handles function exceptions
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local checker = _G.checker

            local ok, err = checker:_run_locked("key", function()
                error("oh no!")
                return true
            end)

            -- remove "content_by_lua(nginx.conf:<lineno>)" context and such from
            -- the error string so that our test is a little more stable
            err = err:gsub(" content_by_lua[^ ]+", "")

            ngx.say(ok)
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
nil
locked function threw an exception: oh no!
--- no_error_log
[error]



=== TEST 6: run_locked() returns errors from the locked function
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local checker = _G.checker

            local ok, err = checker:_run_locked("key", function()
                return nil, "I've failed you"
            end)

            ngx.say(ok)
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
nil
I've failed you
--- no_error_log
[error]



=== TEST 7: run_locked() logs errors/exceptions from scheduled functions
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        set_by_lua_block $test {
            local checker = _G.checker

            local key = "my_lock_key"

            local resty_lock = require "resty.lock"
            local lock = assert(resty_lock:new(checker.shm_name))
            assert(lock:lock(key))
            ngx.ctx.lock = lock

            local t = { count = 0 }
            ngx.ctx.t = t

            local ok, err = checker:_run_locked(key, function()
                t.count = t.count + 1
                error("LOCK EXCEPTION")
            end)

            assert(err == nil, "expected no error")
            assert(ok == "scheduled", "expected the function to be scheduled")

            local ok, err = checker:_run_locked(key, function()
                t.count = t.count + 1
                return nil, "LOCK ERROR"
            end)

            assert(err == nil, "expected no error")
            assert(ok == "scheduled", "expected the function to be scheduled")

            local ok, err = checker:_run_locked(key, function()
                t.count = t.count + 1
                return true
            end)

            assert(err == nil, "expected no error")
            assert(ok == "scheduled", "expected the function to be scheduled")
        }

        content_by_lua_block {
            assert(ngx.ctx.lock:unlock())

            local t = ngx.ctx.t

            for i = 1, 10 do
                if t.count >= 3 then
                    break
                end
                ngx.sleep(0.25)
            end

            ngx.say(t.count)
        }
    }
--- request
GET /t
--- response_body
3
--- error_log
LOCK ERROR
LOCK EXCEPTION



=== TEST 8: run_locked() passes any/all arguments to the locked function
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local checker = _G.checker

            local sum = 0
            local ok, err = checker:_run_locked("key", function(a, b, c)
                sum = sum + a + b + c
                return true
            end, 1, 2, 3)

            ngx.say(ok)
            ngx.say(err)
            ngx.say(sum)
        }
    }
--- request
GET /t
--- response_body
true
nil
6
--- no_error_log
[error]
