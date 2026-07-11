use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
plan tests => repeat_each() * 7;

run_tests();

__DATA__

=== TEST 1: Service not found → status 5 (NOT_FOUND)
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open("/tmp/test_err.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Echo_PingRequest {}
            message Echo_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.Client.new
        Yar.Client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params) return "ok" end
            return client
        end

        require("resty.grpc_yar_proxy").setup {
            services = {
                Echo = { proto = "/tmp/test_err.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    location ~ ^/[^/]+/ {
        content_by_lua_block {
            require("resty.grpc_yar_proxy").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local codec = require("resty.grpc_yar_proxy.codec")
            local frame = codec.encode_frame("")

            local res = ngx.location.capture("/Unknown/Ping", {
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
grpc_status=5
grpc_message=service not found: Unknown
--- no_error_log
[error]

=== TEST 2: Invalid gRPC path → status 13 (INTERNAL)
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open("/tmp/test_err2.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Echo_PingRequest {}
            message Echo_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.Client.new
        Yar.Client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params) return "ok" end
            return client
        end

        require("resty.grpc_yar_proxy").setup {
            services = {
                Echo = { proto = "/tmp/test_err2.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    location /grpc {
        content_by_lua_block {
            require("resty.grpc_yar_proxy").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local codec = require("resty.grpc_yar_proxy.codec")
            local frame = codec.encode_frame("")

            -- Path with only one segment (invalid)
            local res = ngx.location.capture("/grpc", {
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

=== TEST 3: Compression flag → status 12 (UNIMPLEMENTED)
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open("/tmp/test_err3.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Echo_PingRequest {}
            message Echo_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.Client.new
        Yar.Client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params) return "ok" end
            return client
        end

        require("resty.grpc_yar_proxy").setup {
            services = {
                Echo = { proto = "/tmp/test_err3.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    location ~ ^/Echo/ {
        content_by_lua_block {
            require("resty.grpc_yar_proxy").serve()
        }
    }
    location /test {
        content_by_lua_block {
            -- Construct frame with compression flag = 1
            local Util = require("yar.util")
            local compressed_frame = string.char(1) .. Util.pack_u32(5) .. "hello"

            local res = ngx.location.capture("/Echo/Ping", {
                method = ngx.HTTP_POST,
                body = compressed_frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
            ngx.say("grpc_message=" .. (res.header["grpc-message"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=12
grpc_message=compression not supported
--- no_error_log
[error]

=== TEST 4: Empty body → status 13 (INTERNAL)
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open("/tmp/test_err4.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Echo_PingRequest {}
            message Echo_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.Client.new
        Yar.Client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params) return "ok" end
            return client
        end

        require("resty.grpc_yar_proxy").setup {
            services = {
                Echo = { proto = "/tmp/test_err4.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    location ~ ^/Echo/ {
        content_by_lua_block {
            require("resty.grpc_yar_proxy").serve()
        }
    }
    location /test {
        content_by_lua_block {
            -- Empty body
            local res = ngx.location.capture("/Echo/Ping", {
                method = ngx.HTTP_POST,
                body = "",
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

=== TEST 5: Missing proto field → setup error
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local ok, err = pcall(require("resty.grpc_yar_proxy").setup, {
            services = {
                Bad = { url = "http://mock/api" },
            },
        })
        if not ok then
            _G.setup_err = err
        end
    }
--- config
    location /test {
        content_by_lua_block {
            ngx.say(_G.setup_err or "no error")
        }
    }
--- request
GET /test
--- response_body
grpc_yar_proxy: service 'Bad' is missing or has invalid 'proto' field
--- no_error_log
[error]

=== TEST 6: Missing url field → setup error
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local f = io.open("/tmp/test_nourl.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message NoUrl_PingRequest {}
            message NoUrl_PingResponse { string result = 1; }
        ]]))
        f:close()

        local ok, err = pcall(require("resty.grpc_yar_proxy").setup, {
            services = {
                NoUrl = { proto = "/tmp/test_nourl.pb" },
            },
        })
        if not ok then
            _G.setup_err = err
        end
    }
--- config
    location /test {
        content_by_lua_block {
            ngx.say(_G.setup_err or "no error")
        }
    }
--- request
GET /test
--- response_body
grpc_yar_proxy: service 'NoUrl' is missing or has invalid 'url' field
--- no_error_log
[error]

=== TEST 7: options not a table → setup error
--- http_config
    lua_package_path ";;";
    init_by_lua_block {
        local protoc = require("protoc")
        local f = io.open("/tmp/test_badopt.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message BadOpt_PingRequest {}
            message BadOpt_PingResponse { string result = 1; }
        ]]))
        f:close()

        local ok, err = pcall(require("resty.grpc_yar_proxy").setup, {
            services = {
                BadOpt = { proto = "/tmp/test_badopt.pb", url = "http://mock/api", options = "not_a_table" },
            },
        })
        if not ok then
            _G.setup_err = err
        end
    }
--- config
    location /test {
        content_by_lua_block {
            ngx.say(_G.setup_err or "no error")
        }
    }
--- request
GET /test
--- response_body
grpc_yar_proxy: service 'BadOpt' options must be a table
--- no_error_log
[error]
