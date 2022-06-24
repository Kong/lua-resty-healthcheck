use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 2;

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

=== TEST 1: set_all_target_statuses_for_hostname() updates statuses
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
events_module = "resty.events",
            })
            checker:add_target("127.0.0.1", 2112, "rush", true)
            checker:add_target("127.0.0.2", 2112, "rush", true)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2112, "rush"))  -- true
            ngx.say(checker:get_target_status("127.0.0.2", 2112, "rush"))  -- true
            checker:set_all_target_statuses_for_hostname("rush", 2112, false)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2112, "rush"))  -- false
            ngx.say(checker:get_target_status("127.0.0.2", 2112, "rush"))  -- false
            checker:set_all_target_statuses_for_hostname("rush", 2112, true)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2112, "rush"))  -- true
            ngx.say(checker:get_target_status("127.0.0.2", 2112, "rush"))  -- true
        }
    }
--- request
GET /t
--- response_body
true
true
false
false
true
true


=== TEST 2: set_all_target_statuses_for_hostname() restores node after passive check disables it
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
events_module = "resty.events",
                checks = {
                    passive = {
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 2,
                        }
                    }
                }
            })
            checker:add_target("127.0.0.1", 2112, "rush", true)
            checker:add_target("127.0.0.2", 2112, "rush", true)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2112, "rush"))  -- true
            ngx.say(checker:get_target_status("127.0.0.2", 2112, "rush"))  -- true
            checker:report_http_status("127.0.0.1", 2112, "rush", 500)
            checker:report_http_status("127.0.0.1", 2112, "rush", 500)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2112, "rush"))  -- false
            checker:set_all_target_statuses_for_hostname("rush", 2112, true)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2112, "rush"))  -- true
            ngx.say(checker:get_target_status("127.0.0.2", 2112, "rush"))  -- true
        }
    }
--- request
GET /t
--- response_body
true
true
false
true
true


=== TEST 3: set_all_target_statuses_for_hostname() resets failure counters
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
events_module = "resty.events",
                checks = {
                    passive = {
                        healthy = {
                            successes = 2,
                        },
                        unhealthy = {
                            tcp_failures = 2,
                            http_failures = 2,
                        }
                    }
                }
            })
            checker:add_target("127.0.0.1", 2112, "rush", true)
            checker:add_target("127.0.0.2", 2112, "rush", true)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2112, "rush"))  -- true
            ngx.say(checker:get_target_status("127.0.0.2", 2112, "rush"))  -- true
            checker:report_http_status("127.0.0.1", 2112, "rush", 500)
            checker:set_all_target_statuses_for_hostname("rush", 2112, true)
            checker:report_http_status("127.0.0.1", 2112, "rush", 500)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2112, "rush"))  -- true
            ngx.say(checker:get_target_status("127.0.0.2", 2112, "rush"))  -- true
            checker:report_http_status("127.0.0.1", 2112, "rush", 500)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2112, "rush"))  -- false
            ngx.say(checker:get_target_status("127.0.0.2", 2112, "rush"))  -- true
        }
    }
--- request
GET /t
--- response_body
true
true
true
true
false
true


=== TEST 4: set_target_status() resets the success counters
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    passive = {
                        healthy = {
                            successes = 2,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 2,
                        }
                    }
                }
            })
            checker:add_target("127.0.0.1", 2112, "rush", true)
            checker:add_target("127.0.0.2", 2112, "rush", true)
            ngx.sleep(0.01)
            checker:set_all_target_statuses_for_hostname("rush", 2112, false)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2112, "rush"))  -- false
            ngx.say(checker:get_target_status("127.0.0.2", 2112, "rush"))  -- false
            checker:report_http_status("127.0.0.1", 2112, "rush", 200)
            checker:set_all_target_statuses_for_hostname("rush", 2112, false)
            checker:report_http_status("127.0.0.1", 2112, "rush", 200)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2112, "rush"))  -- false
            ngx.say(checker:get_target_status("127.0.0.2", 2112, "rush"))  -- false
            checker:report_http_status("127.0.0.1", 2112, "rush", 200)
            ngx.sleep(0.01)
            ngx.say(checker:get_target_status("127.0.0.1", 2112, "rush"))  -- true
            ngx.say(checker:get_target_status("127.0.0.2", 2112, "rush"))  -- false
        }
    }
--- request
GET /t
--- response_body
false
false
false
false
true
false
