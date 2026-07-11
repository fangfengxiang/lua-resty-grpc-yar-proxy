use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
plan tests => repeat_each() * 2;

run_tests();

__DATA__

=== TEST 1: Multiple gRPC frames → streaming rejection (status 12)
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open("/tmp/test_stream.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Str_SendRequest { string data = 1; }
            message Str_SendResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.Client.new
        Yar.Client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params)
                return "ok"
            end
            return client
        end

        require("resty.grpc_yar_proxy").setup {
            services = {
                Str = { proto = "/tmp/test_stream.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    location ~ ^/Str/ {
        content_by_lua_block {
            require("resty.grpc_yar_proxy").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local codec = require("resty.grpc_yar_proxy.codec")

            -- Two frames = streaming
            local frame1 = codec.encode_frame("first")
            local frame2 = codec.encode_frame("second")
            local body = frame1 .. frame2

            local res = ngx.location.capture("/Str/Send", {
                method = ngx.HTTP_POST,
                body = body,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
            ngx.say("grpc_message=" .. (res.header["grpc-message"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=12
grpc_message=streaming mode not supported
--- no_error_log
[error]

=== TEST 2: Single frame = Unary (not rejected)
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open("/tmp/test_stream2.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Str_SendRequest { string data = 1; }
            message Str_SendResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.Client.new
        Yar.Client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params)
                return "ok"
            end
            return client
        end

        require("resty.grpc_yar_proxy").setup {
            services = {
                Str = { proto = "/tmp/test_stream2.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    location ~ ^/Str/ {
        content_by_lua_block {
            require("resty.grpc_yar_proxy").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local pb = require("pb")
            local codec = require("resty.grpc_yar_proxy.codec")

            local payload = pb.encode("Str_SendRequest", { data = "hello" })
            local frame = codec.encode_frame(payload)

            local res = ngx.location.capture("/Str/Send", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=0
--- no_error_log
[error]
