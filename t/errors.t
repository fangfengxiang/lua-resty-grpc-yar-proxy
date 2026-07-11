use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
plan tests => repeat_each() * 6;

run_tests();

__DATA__

=== TEST 1: map_yar_error — transport prefix → UNAVAILABLE (14)
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local errors = require("resty.grpc_yar_proxy.errors")
            local status, msg = errors.map_yar_error("transport: connection refused")
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=14
msg=transport: connection refused
--- no_error_log
[error]

=== TEST 2: map_yar_error — timeout prefix → DEADLINE_EXCEEDED (4)
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local errors = require("resty.grpc_yar_proxy.errors")
            local status, msg = errors.map_yar_error("timeout: read timeout")
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=4
msg=timeout: read timeout
--- no_error_log
[error]

=== TEST 3: map_yar_error — protocol prefix → INTERNAL (13)
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local errors = require("resty.grpc_yar_proxy.errors")
            local status, msg = errors.map_yar_error("protocol: invalid magic number")
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=13
msg=protocol: invalid magic number
--- no_error_log
[error]

=== TEST 4: map_yar_error — no prefix (business error) → INTERNAL (13)
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local errors = require("resty.grpc_yar_proxy.errors")
            local status, msg = errors.map_yar_error("method not found: doStuff")
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=13
msg=method not found: doStuff
--- no_error_log
[error]

=== TEST 5: map_yar_error — nil error → INTERNAL (13)
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local errors = require("resty.grpc_yar_proxy.errors")
            local status, msg = errors.map_yar_error(nil)
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=13
msg=unknown error
--- no_error_log
[error]

=== TEST 6: gRPC status code constants
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local errors = require("resty.grpc_yar_proxy.errors")
            ngx.say("OK=" .. errors.OK)
            ngx.say("NOT_FOUND=" .. errors.NOT_FOUND)
            ngx.say("INTERNAL=" .. errors.INTERNAL)
            ngx.say("UNIMPLEMENTED=" .. errors.UNIMPLEMENTED)
            ngx.say("UNAVAILABLE=" .. errors.UNAVAILABLE)
            ngx.say("DEADLINE_EXCEEDED=" .. errors.DEADLINE_EXCEEDED)
        }
    }
--- request
GET /t
--- response_body
OK=0
NOT_FOUND=5
INTERNAL=13
UNIMPLEMENTED=12
UNAVAILABLE=14
DEADLINE_EXCEEDED=4
--- no_error_log
[error]
