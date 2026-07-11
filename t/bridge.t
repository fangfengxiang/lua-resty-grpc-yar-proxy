use Test::Nginx::Socket::Lua;

repeat_each(2);
plan tests => repeat_each() * 12;

run_tests();

__DATA__

=== TEST 1: parse_grpc_path — normal path
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local bridge = require("resty.grpc_yar_proxy.bridge")
            local service, method, err = bridge.parse_grpc_path("/Calculator/Add")
            ngx.say("service=" .. service)
            ngx.say("method=" .. method)
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /t
--- response_body
service=Calculator
method=Add
err=nil
--- no_error_log
[error]

=== TEST 2: parse_grpc_path — invalid path (single segment)
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local bridge = require("resty.grpc_yar_proxy.bridge")
            local service, method, err = bridge.parse_grpc_path("/foo")
            ngx.say("service=" .. tostring(service))
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /t
--- response_body
service=nil
err=invalid gRPC path: /foo
--- no_error_log
[error]

=== TEST 3: parse_grpc_path — invalid path (three segments)
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local bridge = require("resty.grpc_yar_proxy.bridge")
            local service, method, err = bridge.parse_grpc_path("/foo/bar/baz")
            ngx.say("service=" .. tostring(service))
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /t
--- response_body
service=nil
err=invalid gRPC path: /foo/bar/baz
--- no_error_log
[error]

=== TEST 4: method_to_yar — first letter lowercase
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local bridge = require("resty.grpc_yar_proxy.bridge")
            ngx.say(bridge.method_to_yar("Add"))
            ngx.say(bridge.method_to_yar("GetUser"))
            ngx.say(bridge.method_to_yar("getUser"))
            ngx.say(bridge.method_to_yar("a"))
        }
    }
--- request
GET /t
--- response_body
add
getUser
getUser
a
--- no_error_log
[error]

=== TEST 5: extract_params — multi params by field number
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():parse([[
                syntax = "proto3";
                message Test_AddRequest { int32 a = 1; int32 b = 2; }
            ]])
            local bridge = require("resty.grpc_yar_proxy.bridge")
            local decoded = { a = 10, b = 20 }
            local params = bridge.extract_params(decoded, "Test_AddRequest")
            ngx.say("params[1]=" .. params[1])
            ngx.say("params[2]=" .. params[2])
            ngx.say("count=" .. #params)
        }
    }
--- request
GET /t
--- response_body
params[1]=10
params[2]=20
count=2
--- no_error_log
[error]

=== TEST 6: extract_params — single param
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():parse([[
                syntax = "proto3";
                message Test_GetRequest { int32 id = 1; }
            ]])
            local bridge = require("resty.grpc_yar_proxy.bridge")
            local decoded = { id = 42 }
            local params = bridge.extract_params(decoded, "Test_GetRequest")
            ngx.say("params[1]=" .. params[1])
            ngx.say("count=" .. #params)
        }
    }
--- request
GET /t
--- response_body
params[1]=42
count=1
--- no_error_log
[error]

=== TEST 7: extract_params — empty params (no fields)
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():parse([[
                syntax = "proto3";
                message Test_EmptyRequest {}
            ]])
            local bridge = require("resty.grpc_yar_proxy.bridge")
            local params = bridge.extract_params({}, "Test_EmptyRequest")
            ngx.say("count=" .. #params)
        }
    }
--- request
GET /t
--- response_body
count=0
--- no_error_log
[error]

=== TEST 8: map_response — scalar retval → { result = retval }
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():parse([[
                syntax = "proto3";
                message Test_AddResponse { int32 result = 1; }
            ]])
            local bridge = require("resty.grpc_yar_proxy.bridge")
            local result = bridge.map_response(42, "Test_AddResponse")
            ngx.say("result=" .. result.result)
            ngx.say("type=" .. type(result))
        }
    }
--- request
GET /t
--- response_body
result=42
type=table
--- no_error_log
[error]

=== TEST 9: map_response — associative table → direct use
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():parse([[
                syntax = "proto3";
                message Test_GetUserResponse { string name = 1; int32 age = 2; }
            ]])
            local bridge = require("resty.grpc_yar_proxy.bridge")
            local retval = { name = "alice", age = 18 }
            local result = bridge.map_response(retval, "Test_GetUserResponse")
            ngx.say("name=" .. result.name)
            ngx.say("age=" .. result.age)
        }
    }
--- request
GET /t
--- response_body
name=alice
age=18
--- no_error_log
[error]

=== TEST 10: map_response — nil retval → empty table
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():parse([[
                syntax = "proto3";
                message Test_EmptyResponse {}
            ]])
            local bridge = require("resty.grpc_yar_proxy.bridge")
            local result = bridge.map_response(nil, "Test_EmptyResponse")
            local count = 0
            for _ in pairs(result) do count = count + 1 end
            ngx.say("count=" .. count)
        }
    }
--- request
GET /t
--- response_body
count=0
--- no_error_log
[error]

=== TEST 11: map_response — index array → field 1 (repeated) as key
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():parse([[
                syntax = "proto3";
                message Test_ListResponse { repeated string items = 1; }
            ]])
            local bridge = require("resty.grpc_yar_proxy.bridge")
            local retval = { "a", "b", "c" }
            local result = bridge.map_response(retval, "Test_ListResponse")
            ngx.say("items_count=" .. #result.items)
            ngx.say("items[1]=" .. result.items[1])
            ngx.say("items[2]=" .. result.items[2])
            ngx.say("items[3]=" .. result.items[3])
        }
    }
--- request
GET /t
--- response_body
items_count=3
items[1]=a
items[2]=b
items[3]=c
--- no_error_log
[error]

=== TEST 12: map_response — index array with non-repeated field 1, repeated field 2
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():parse([[
                syntax = "proto3";
                message Test_NonRepResponse { int32 count = 1; repeated string names = 2; }
            ]])
            local bridge = require("resty.grpc_yar_proxy.bridge")
            local retval = { "alice", "bob" }
            local result = bridge.map_response(retval, "Test_NonRepResponse")
            -- field 1 is "count" (not repeated), so falls back to first repeated "names"
            ngx.say("names_count=" .. #result.names)
            ngx.say("names[1]=" .. result.names[1])
            ngx.say("names[2]=" .. result.names[2])
        }
    }
--- request
GET /t
--- response_body
names_count=2
names[1]=alice
names[2]=bob
--- no_error_log
[error]
