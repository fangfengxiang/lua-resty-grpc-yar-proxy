use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
plan tests => repeat_each() * 3 * 8;

run_tests();

__DATA__

=== TEST 1: circuit breaker — CLOSED state allows requests
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local cb = require("resty.grpc_yar_proxy.circuit_breaker")
            cb.init({ failure_threshold = 3, cooldown_ms = 100 })
            cb.reset_all()
            local allowed = cb.allow("http://example.com/api")
            ngx.say("allowed=" .. tostring(allowed))
            ngx.say("state=" .. cb.get_state("http://example.com/api"))
        }
    }
--- request
GET /t
--- response_body
allowed=true
state=closed
--- no_error_log
[error]

=== TEST 2: circuit breaker — failures below threshold stay CLOSED
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local cb = require("resty.grpc_yar_proxy.circuit_breaker")
            local Yar = require("yar")
            cb.init({ failure_threshold = 3, cooldown_ms = 100 })
            cb.reset_all()
            cb.record_failure("http://example.com/api", Yar.Error.TRANSPORT)
            cb.record_failure("http://example.com/api", Yar.Error.TRANSPORT)
            local allowed = cb.allow("http://example.com/api")
            ngx.say("allowed=" .. tostring(allowed))
            ngx.say("state=" .. cb.get_state("http://example.com/api"))
        }
    }
--- request
GET /t
--- response_body
allowed=true
state=closed
--- no_error_log
[error]

=== TEST 3: circuit breaker — threshold reached opens circuit
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local cb = require("resty.grpc_yar_proxy.circuit_breaker")
            local Yar = require("yar")
            cb.init({ failure_threshold = 3, cooldown_ms = 100 })
            cb.reset_all()
            cb.record_failure("http://example.com/api", Yar.Error.TRANSPORT)
            cb.record_failure("http://example.com/api", Yar.Error.TRANSPORT)
            cb.record_failure("http://example.com/api", Yar.Error.TRANSPORT)
            local allowed = cb.allow("http://example.com/api")
            ngx.say("allowed=" .. tostring(allowed))
            ngx.say("state=" .. cb.get_state("http://example.com/api"))
        }
    }
--- request
GET /t
--- response_body
allowed=false
state=open
--- no_error_log
[error]

=== TEST 4: circuit breaker — OPEN rejects requests
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local cb = require("resty.grpc_yar_proxy.circuit_breaker")
            local Yar = require("yar")
            cb.init({ failure_threshold = 2, cooldown_ms = 60000 })
            cb.reset_all()
            cb.record_failure("http://example.com/api", Yar.Error.TRANSPORT)
            cb.record_failure("http://example.com/api", Yar.Error.TRANSPORT)
            local allowed = cb.allow("http://example.com/api")
            ngx.say("allowed=" .. tostring(allowed))
            ngx.say("state=" .. cb.get_state("http://example.com/api"))
        }
    }
--- request
GET /t
--- response_body
allowed=false
state=open
--- no_error_log
[error]

=== TEST 5: circuit breaker — success resets to CLOSED
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local cb = require("resty.grpc_yar_proxy.circuit_breaker")
            local Yar = require("yar")
            cb.init({ failure_threshold = 3, cooldown_ms = 100 })
            cb.reset_all()
            cb.record_failure("http://example.com/api", Yar.Error.TRANSPORT)
            cb.record_success("http://example.com/api")
            local allowed = cb.allow("http://example.com/api")
            ngx.say("allowed=" .. tostring(allowed))
            ngx.say("state=" .. cb.get_state("http://example.com/api"))
        }
    }
--- request
GET /t
--- response_body
allowed=true
state=closed
--- no_error_log
[error]

=== TEST 6: circuit breaker — protocol errors do NOT trigger failure count
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local cb = require("resty.grpc_yar_proxy.circuit_breaker")
            local Yar = require("yar")
            cb.init({ failure_threshold = 2, cooldown_ms = 100 })
            cb.reset_all()
            cb.record_failure("http://example.com/api", Yar.Error.PROTOCOL)
            cb.record_failure("http://example.com/api", Yar.Error.PROTOCOL)
            local allowed = cb.allow("http://example.com/api")
            ngx.say("allowed=" .. tostring(allowed))
            ngx.say("state=" .. cb.get_state("http://example.com/api"))
        }
    }
--- request
GET /t
--- response_body
allowed=true
state=closed
--- no_error_log
[error]

=== TEST 7: circuit breaker — different URLs are independent
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local cb = require("resty.grpc_yar_proxy.circuit_breaker")
            local Yar = require("yar")
            cb.init({ failure_threshold = 2, cooldown_ms = 60000 })
            cb.reset_all()
            cb.record_failure("http://a.com/api", Yar.Error.TRANSPORT)
            cb.record_failure("http://a.com/api", Yar.Error.TRANSPORT)
            local allowed_a = cb.allow("http://a.com/api")
            local allowed_b = cb.allow("http://b.com/api")
            ngx.say("a=" .. tostring(allowed_a))
            ngx.say("b=" .. tostring(allowed_b))
            ngx.say("state_a=" .. cb.get_state("http://a.com/api"))
            ngx.say("state_b=" .. cb.get_state("http://b.com/api"))
        }
    }
--- request
GET /t
--- response_body
a=false
b=true
state_a=open
state_b=closed
--- no_error_log
[error]

=== TEST 8: circuit breaker — cooldown transitions OPEN to HALF_OPEN
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local cb = require("resty.grpc_yar_proxy.circuit_breaker")
            local Yar = require("yar")
            cb.init({ failure_threshold = 1, cooldown_ms = 100 })
            cb.reset_all()
            cb.record_failure("http://example.com/api", Yar.Error.TRANSPORT)
            -- State should be OPEN
            ngx.say("before=" .. cb.get_state("http://example.com/api"))
            -- Wait for cooldown (100ms)
            ngx.sleep(0.15)
            -- allow() should transition to HALF_OPEN and return true
            local allowed = cb.allow("http://example.com/api")
            ngx.say("allowed=" .. tostring(allowed))
            ngx.say("after=" .. cb.get_state("http://example.com/api"))
        }
    }
--- request
GET /t
--- response_body
before=open
allowed=true
after=half_open
--- no_error_log
[error]
