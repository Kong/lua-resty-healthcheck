BEGIN {
    if ($ENV{TEST_NGINX_CHECK_LEAK}) {
        $SkipReason = "unavailable for the hup tests";

    } else {
        $ENV{TEST_NGINX_USE_HUP} = 1;
        undef $ENV{TEST_NGINX_USE_STAP};
    }
}


use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(cwd);

workers(1);
no_shuffle();

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__

=== TEST 1: get_target_status() reports proper status
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2115;
        location = /status {
            return 200;
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
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 999, -- we don't want active checks
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 1,
                            http_failures = 1,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 1,
                        },
                        unhealthy  = {
                            tcp_failures = 1,
                            http_failures = 1,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2115, "foo.com", true)
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "foo.com"))  -- true
            checker:report_tcp_failure("127.0.0.1", 2115, "foo.com")
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "foo.com"))  -- false
            checker:report_success("127.0.0.1", 2115, "foo.com")
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "foo.com"))  -- true
        }
    }
--- request
GET /t
--- response_body
true
false
true
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: nothing to do
--- no_error_log
checking healthy targets: #1
checking unhealthy targets: #1



=== TEST 2: get_target_status() again
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2115;
        location = /status {
            return 200;
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
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 999, -- we don't want active checks
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 1,
                            http_failures = 1,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 1,
                        },
                        unhealthy  = {
                            tcp_failures = 1,
                            http_failures = 1,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2115, "foo.com", true)
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "foo.com"))  -- true
            checker:report_tcp_failure("127.0.0.1", 2115, "foo.com")
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "foo.com"))  -- false
            checker:report_success("127.0.0.1", 2115, "foo.com")
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "foo.com"))  -- true
        }
    }
--- request
GET /t
--- response_body
true
false
true
--- error_log
Got initial target list
Got initial status healthy foo.com 127.0.0.1:2115
--- no_error_log
checking healthy targets: #1
checking unhealthy targets: #1
