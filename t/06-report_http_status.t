use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * 50;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__



=== TEST 1: report_http_status() failures active + passive
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
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 999, -- we don't want active checks
                            successes = 3,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            local ok, err = checker:add_target("127.0.0.1", 2113, nil, true)
            checker:report_http_status("127.0.0.1", 2112, 500, "active")
            checker:report_http_status("127.0.0.1", 2113, 500, "passive")
            checker:report_http_status("127.0.0.1", 2112, 500, "active")
            checker:report_http_status("127.0.0.1", 2113, 500, "passive")
            checker:report_http_status("127.0.0.1", 2112, 500, "active")
            checker:report_http_status("127.0.0.1", 2113, 500, "passive")
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- false
            ngx.say(checker:get_target_status("127.0.0.1", 2113))  -- false
        }
    }
--- request
GET /t
--- response_body
false
false
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: nothing to do
unhealthy HTTP increment (1/3) for 127.0.0.1:2112
unhealthy HTTP increment (2/3) for 127.0.0.1:2112
unhealthy HTTP increment (3/3) for 127.0.0.1:2112
event: target status '127.0.0.1:2112' from 'true' to 'false'
unhealthy HTTP increment (1/3) for 127.0.0.1:2113
unhealthy HTTP increment (2/3) for 127.0.0.1:2113
unhealthy HTTP increment (3/3) for 127.0.0.1:2113
event: target status '127.0.0.1:2113' from 'true' to 'false'



=== TEST 2: report_http_status() successes active + passive
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
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 999, -- we don't want active checks
                            successes = 4,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 4,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, false)
            local ok, err = checker:add_target("127.0.0.1", 2113, nil, false)
            checker:report_http_status("127.0.0.1", 2112, 200, "active")
            checker:report_http_status("127.0.0.1", 2113, 200, "passive")
            checker:report_http_status("127.0.0.1", 2112, 200, "active")
            checker:report_http_status("127.0.0.1", 2113, 200, "passive")
            checker:report_http_status("127.0.0.1", 2112, 200, "active")
            checker:report_http_status("127.0.0.1", 2113, 200, "passive")
            checker:report_http_status("127.0.0.1", 2112, 200, "active")
            checker:report_http_status("127.0.0.1", 2113, 200, "passive")
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- true
            ngx.say(checker:get_target_status("127.0.0.1", 2113))  -- true
        }
    }
--- request
GET /t
--- response_body
true
true
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: nothing to do
healthy SUCCESS increment (1/4) for 127.0.0.1:2112
healthy SUCCESS increment (2/4) for 127.0.0.1:2112
healthy SUCCESS increment (3/4) for 127.0.0.1:2112
healthy SUCCESS increment (4/4) for 127.0.0.1:2112
event: target status '127.0.0.1:2112' from 'false' to 'true'
healthy SUCCESS increment (1/4) for 127.0.0.1:2113
healthy SUCCESS increment (2/4) for 127.0.0.1:2113
healthy SUCCESS increment (3/4) for 127.0.0.1:2113
healthy SUCCESS increment (4/4) for 127.0.0.1:2113
event: target status '127.0.0.1:2113' from 'false' to 'true'


=== TEST 3: report_http_status() with success is a nop when passive.healthy.successes == 0
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
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 999, -- we don't want active checks
                            successes = 4,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 0,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, false)
            checker:report_http_status("127.0.0.1", 2112, 200, "passive")
            checker:report_http_status("127.0.0.1", 2112, 200, "passive")
            checker:report_http_status("127.0.0.1", 2112, 200, "passive")
            checker:report_http_status("127.0.0.1", 2112, 200, "passive")
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- false
        }
    }
--- request
GET /t
--- response_body
false
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: nothing to do
--- no_error_log
healthy SUCCESS increment
event: target status '127.0.0.1:2112' from 'false' to 'true'


=== TEST 4: report_http_status() with success is a nop when active.healthy.successes == 0
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
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 999, -- we don't want active checks
                            successes = 0,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 4,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, false)
            checker:report_http_status("127.0.0.1", 2112, 200, "active")
            checker:report_http_status("127.0.0.1", 2112, 200, "active")
            checker:report_http_status("127.0.0.1", 2112, 200, "active")
            checker:report_http_status("127.0.0.1", 2112, 200, "active")
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- false
        }
    }
--- request
GET /t
--- response_body
false
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: nothing to do
--- no_error_log
healthy SUCCESS increment
event: target status '127.0.0.1:2112' from 'false' to 'true'


=== TEST 5: report_http_status() with failure is a nop when passive.unhealthy.http_failures == 0
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
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 999, -- we don't want active checks
                            successes = 4,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 4,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 0,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            checker:report_http_status("127.0.0.1", 2112, 500, "passive")
            checker:report_http_status("127.0.0.1", 2112, 500, "passive")
            checker:report_http_status("127.0.0.1", 2112, 500, "passive")
            checker:report_http_status("127.0.0.1", 2112, 500, "passive")
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: nothing to do
--- no_error_log
unhealthy HTTP increment
event: target status '127.0.0.1:2112' from 'true' to 'false'


=== TEST 4: report_http_status() with success is a nop when active.unhealthy.http_failures == 0
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
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 999, -- we don't want active checks
                            successes = 4,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 2,
                            http_failures = 0,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 4,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    }
                }
            })
            ngx.sleep(0.1) -- wait for initial timers to run once
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            checker:report_http_status("127.0.0.1", 2112, 500, "active")
            checker:report_http_status("127.0.0.1", 2112, 500, "active")
            checker:report_http_status("127.0.0.1", 2112, 500, "active")
            checker:report_http_status("127.0.0.1", 2112, 500, "active")
            ngx.say(checker:get_target_status("127.0.0.1", 2112))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: nothing to do
--- no_error_log
unhealthy HTTP increment
event: target status '127.0.0.1:2112' from 'true' to 'false'
