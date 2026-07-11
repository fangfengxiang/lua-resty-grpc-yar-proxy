use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
plan tests => repeat_each() * 3 * 6;

run_tests();

__DATA__

=== TEST 1: Full gRPC → YAR → gRPC flow (mock client, scalar response)
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open("/tmp/test_calc.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Calc_AddRequest { int32 a = 1; int32 b = 2; }
            message Calc_AddResponse { int32 result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.Client.new
        Yar.Client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params)
                if method == "add" then
                    return (params[1] or 0) + (params[2] or 0)
                end
                return nil, "method not found: " .. method
            end
            return client
        end

        require("resty.grpc_yar_proxy").setup {
            services = {
                Calc = { proto = "/tmp/test_calc.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    location ~ ^/Calc/ {
        content_by_lua_block {
            require("resty.grpc_yar_proxy").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local pb = require("pb")
            local codec = require("resty.grpc_yar_proxy.codec")

            local payload = pb.encode("Calc_AddRequest", { a = 3, b = 4 })
            local frame = codec.encode_frame(payload)

            local res = ngx.location.capture("/Calc/Add", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("http_status=" .. res.status)
            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))

            local flag, resp_payload = codec.decode_frame(res.body)
            if resp_payload then
                local result = pb.decode("Calc_AddResponse", resp_payload)
                ngx.say("result=" .. (result and result.result or "nil"))
            else
                ngx.say("result=decode_failed")
            end
        }
    }
--- request
GET /test
--- response_body
http_status=200
grpc_status=0
result=7
--- no_error_log
[error]

=== TEST 2: Full flow with associative array response
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open("/tmp/test_user.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message User_GetRequest { int32 id = 1; }
            message User_GetResponse { string name = 1; int32 age = 2; }
        ]]))
        f:close()

        local orig_new = Yar.Client.new
        Yar.Client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params)
                if method == "get" then
                    return { name = "alice", age = 18 }
                end
                return nil, "method not found"
            end
            return client
        end

        require("resty.grpc_yar_proxy").setup {
            services = {
                User = { proto = "/tmp/test_user.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    location ~ ^/User/ {
        content_by_lua_block {
            require("resty.grpc_yar_proxy").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local pb = require("pb")
            local codec = require("resty.grpc_yar_proxy.codec")

            local payload = pb.encode("User_GetRequest", { id = 1 })
            local frame = codec.encode_frame(payload)

            local res = ngx.location.capture("/User/Get", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))

            local flag, resp_payload = codec.decode_frame(res.body)
            if resp_payload then
                local result = pb.decode("User_GetResponse", resp_payload)
                ngx.say("name=" .. (result and result.name or "nil"))
                ngx.say("age=" .. (result and result.age or "nil"))
            else
                ngx.say("decode=failed")
            end
        }
    }
--- request
GET /test
--- response_body
grpc_status=0
name=alice
age=18
--- no_error_log
[error]

=== TEST 3: YAR call error propagation (transport error → UNAVAILABLE)
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open("/tmp/test_fail.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Fail_PingRequest {}
            message Fail_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.Client.new
        Yar.Client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params)
                return nil, "transport: connection refused"
            end
            return client
        end

        require("resty.grpc_yar_proxy").setup {
            services = {
                Fail = { proto = "/tmp/test_fail.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    location ~ ^/Fail/ {
        content_by_lua_block {
            require("resty.grpc_yar_proxy").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local codec = require("resty.grpc_yar_proxy.codec")
            local frame = codec.encode_frame("")

            local res = ngx.location.capture("/Fail/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
            ngx.say("grpc_message=" .. (res.header["grpc-message"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=14
grpc_message=transport: connection refused
--- no_error_log
[error]

=== TEST 4: Per-service options override (table config with url + options)
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open("/tmp/test_opt.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Opt_PingRequest {}
            message Opt_PingResponse { string result = 1; }
        ]]))
        f:close()

        -- 记录 per-service options 是否被正确传入
        _G.test_opts = nil

        local orig_new = Yar.Client.new
        Yar.Client.new = function(uri)
            local client = orig_new(uri)
            client.set_options = function(self, opts)
                _G.test_opts = opts
            end
            client.call = function(self, method, params)
                return "ok"
            end
            return client
        end

        require("resty.grpc_yar_proxy").setup {
            services = {
                Opt = {
                    proto   = "/tmp/test_opt.pb",
                    url     = "http://mock/api",
                    options = { timeout = 5000, connect_timeout = 1000 },
                },
            },
            yar_options = { timeout = 3000 },
        }
    }
--- config
    location ~ ^/Opt/ {
        content_by_lua_block {
            require("resty.grpc_yar_proxy").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local codec = require("resty.grpc_yar_proxy.codec")
            local frame = codec.encode_frame("")

            local res = ngx.location.capture("/Opt/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
            -- per-service timeout=5000 覆盖全局 timeout=3000
            -- connect_timeout=1000 来自 per-service
            ngx.say("timeout=" .. (_G.test_opts and _G.test_opts.timeout or "nil"))
            ngx.say("connect_timeout=" .. (_G.test_opts and _G.test_opts.connect_timeout or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=0
timeout=5000
connect_timeout=1000
--- no_error_log
[error]

=== TEST 5: protobuf decode failure → INTERNAL (13)
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open("/tmp/test_bad.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Bad_PingRequest {}
            message Bad_PingResponse { string result = 1; }
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
                Bad = { proto = "/tmp/test_bad.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    location ~ ^/Bad/ {
        content_by_lua_block {
            require("resty.grpc_yar_proxy").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local codec = require("resty.grpc_yar_proxy.codec")

            -- 发送无效 protobuf payload（非零随机字节），pb.decode 会失败
            local bad_payload = string.char(0xFF, 0xFF, 0xFF, 0xFF)
            local frame = codec.encode_frame(bad_payload)

            local res = ngx.location.capture("/Bad/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=13
--- no_error_log
[error]

=== TEST 6: Multiple services sharing same .pb file (dedup)
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open("/tmp/test_dedup.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message SvcA_PingRequest {}
            message SvcA_PingResponse { string result = 1; }
            message SvcB_PingRequest {}
            message SvcB_PingResponse { string result = 1; }
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
                SvcA = { proto = "/tmp/test_dedup.pb", url = "http://mock/a" },
                SvcB = { proto = "/tmp/test_dedup.pb", url = "http://mock/b" },
            },
        }
    }
--- config
    location ~ ^/Svc[AB]/ {
        content_by_lua_block {
            require("resty.grpc_yar_proxy").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local codec = require("resty.grpc_yar_proxy.codec")
            local frame = codec.encode_frame("")

            local res_a = ngx.location.capture("/SvcA/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })
            local res_b = ngx.location.capture("/SvcB/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("svc_a=" .. (res_a.header["grpc-status"] or "nil"))
            ngx.say("svc_b=" .. (res_b.header["grpc-status"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
svc_a=0
svc_b=0
--- no_error_log
[error]
