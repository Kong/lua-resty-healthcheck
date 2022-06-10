use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(cwd);

workers(1);

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

=== TEST 1: headers: {"User-Agent: curl/7.29.0"}
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2112;
        location = /status {
            return 200;
        }
    }
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
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1
                        },
                        headers = {"User-Agent: curl/7.29.0"}
                    }
                }
            })
            ngx.sleep(0.2) -- wait twice the interval
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            ngx.say(ok)
            ngx.sleep(0.2) -- wait twice the interval
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking healthy targets: nothing to do
checking healthy targets: #1
GET /status HTTP/1.0
User-Agent: curl/7.29.0
Host: 127.0.0.1



=== TEST 2: headers: {"User-Agent: curl"}
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2112;
        location = /status {
            return 200;
        }
    }
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
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1
                        },
                        headers = {"User-Agent: curl"}
                    }
                }
            })
            ngx.sleep(0.2) -- wait twice the interval
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            ngx.say(ok)
            ngx.sleep(0.2) -- wait twice the interval
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking healthy targets: nothing to do
checking healthy targets: #1
GET /status HTTP/1.0
User-Agent: curl
Host: 127.0.0.1


=== TEST 3: headers: { ["User-Agent"] = "curl" }
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2112;
        location = /status {
            return 200;
        }
    }
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
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1
                        },
                        headers = { ["User-Agent"] = "curl" }
                    }
                }
            })
            ngx.sleep(0.2) -- wait twice the interval
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            ngx.say(ok)
            ngx.sleep(0.2) -- wait twice the interval
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking healthy targets: nothing to do
checking healthy targets: #1
GET /status HTTP/1.0
User-Agent: curl
Host: 127.0.0.1



=== TEST 4: headers: { ["User-Agent"] = {"curl"} }
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2112;
        location = /status {
            return 200;
        }
    }
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
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1
                        },
                        headers = { ["User-Agent"] = {"curl"} }
                    }
                }
            })
            ngx.sleep(0.2) -- wait twice the interval
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            ngx.say(ok)
            ngx.sleep(0.2) -- wait twice the interval
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking healthy targets: nothing to do
checking healthy targets: #1
GET /status HTTP/1.0
User-Agent: curl
Host: 127.0.0.1



=== TEST 5: headers: { ["User-Agent"] = {"curl", "nginx"} }
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2112;
        location = /status {
            return 200;
        }
    }
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
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1
                        },
                        headers = { ["User-Agent"] = {"curl", "nginx"} }
                    }
                }
            })
            ngx.sleep(0.2) -- wait twice the interval
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            ngx.say(ok)
            ngx.sleep(0.2) -- wait twice the interval
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking healthy targets: nothing to do
checking healthy targets: #1
GET /status HTTP/1.0
User-Agent: curl
User-Agent: nginx
Host: 127.0.0.1
