use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
plan tests => repeat_each() * 3 * 10;

run_tests();

__DATA__

=== TEST 1: trace_middleware — generates request ID when no header
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local trace = require("resty.grpc_yar_proxy.trace")
            local hooks = trace.trace_middleware()
            hooks.on_request("add", {1, 2})
            ngx.say("rid_set=" .. tostring(ngx.ctx.request_id ~= nil))
            ngx.say("rid_len=" .. #ngx.ctx.request_id)
        }
    }
--- request
GET /t
--- response_body
rid_set=true
rid_len=8
--- no_error_log
[error]

=== TEST 2: trace_middleware — preserves existing request ID
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local trace = require("resty.grpc_yar_proxy.trace")
            local hooks = trace.trace_middleware()
            ngx.ctx.request_id = "test-rid-123"
            hooks.on_request("add", {1, 2})
            ngx.say("rid=" .. ngx.ctx.request_id)
        }
    }
--- request
GET /t
--- response_body
rid=test-rid-123
--- no_error_log
[error]

=== TEST 3: get_request_id — returns ctx request ID
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local trace = require("resty.grpc_yar_proxy.trace")
            ngx.ctx.request_id = "my-rid"
            ngx.say("rid=" .. trace.get_request_id())
        }
    }
--- request
GET /t
--- response_body
rid=my-rid
--- no_error_log
[error]

=== TEST 4: ensure_request_id — generates if not set
--- http_config
    lua_package_path ";;";
--- config
    location /t {
        content_by_lua_block {
            local trace = require("resty.grpc_yar_proxy.trace")
            local rid = trace.ensure_request_id()
            ngx.say("rid_set=" .. tostring(ngx.ctx.request_id ~= nil))
            ngx.say("rid_match=" .. tostring(rid == ngx.ctx.request_id))
        }
    }
--- request
GET /t
--- response_body
rid_set=true
rid_match=true
--- no_error_log
[error]

=== TEST 5: access_logger — on_response outputs JSON with ok status
--- http_config
    lua_package_path ";;";
    lua_shared_dict grpc_yar_proxy_metrics 1m;
--- config
    location /t {
        content_by_lua_block {
            local log = require("resty.grpc_yar_proxy.log")
            local hooks = log.access_logger()
            ngx.ctx.request_id = "test-rid"
            hooks.on_request("add", {1, 2})
            hooks.on_response("add", 42, nil)
            ngx.say("done=true")
        }
    }
--- request
GET /t
--- response_body
done=true
--- error_log
"status":"ok"
"request_id":"test-rid"
"method":"add"

=== TEST 6: access_logger — on_response logs error status
--- http_config
    lua_package_path ";;";
    lua_shared_dict grpc_yar_proxy_metrics 1m;
--- config
    location /t {
        content_by_lua_block {
            local log = require("resty.grpc_yar_proxy.log")
            local hooks = log.access_logger()
            ngx.ctx.request_id = "test-rid"
            hooks.on_request("add", {1, 2})
            local err_obj = { code = "TRANSPORT", message = "conn refused" }
            hooks.on_response("add", nil, err_obj)
            ngx.say("done=true")
        }
    }
--- request
GET /t
--- response_body
done=true
--- error_log
"status":"transport"
"request_id":"test-rid"

=== TEST 7: access_logger — deferred mode stores entry in ctx
--- http_config
    lua_package_path ";;";
    lua_shared_dict grpc_yar_proxy_metrics 1m;
--- config
    location /t {
        content_by_lua_block {
            local log = require("resty.grpc_yar_proxy.log")
            local hooks = log.access_logger({ defer = true })
            ngx.ctx.request_id = "defer-rid"
            hooks.on_request("add", {1, 2})
            hooks.on_response("add", 42, nil)
            -- In deferred mode, no immediate log output
            -- Entry is stored in ngx.ctx for flush_logs()
            ngx.say("done=true")
        }
    }
--- request
GET /t
--- response_body
done=true
--- no_error_log
"status"

=== TEST 8: flush_logs — outputs deferred entry in log phase
--- http_config
    lua_package_path ";;";
    lua_shared_dict grpc_yar_proxy_metrics 1m;
--- config
    location /t {
        content_by_lua_block {
            local log = require("resty.grpc_yar_proxy.log")
            local hooks = log.access_logger({ defer = true })
            ngx.ctx.request_id = "flush-rid"
            hooks.on_request("add", {1, 2})
            hooks.on_response("add", 42, nil)
            -- Manually call flush_logs to simulate log_by_lua
            log.flush_logs()
            ngx.say("done=true")
        }
    }
--- request
GET /t
--- response_body
done=true
--- error_log
"status":"ok"
"request_id":"flush-rid"

=== TEST 9: metrics_recorder — records counters in shared dict
--- http_config
    lua_package_path ";;";
    lua_shared_dict grpc_yar_proxy_metrics 1m;
--- config
    location /t {
        content_by_lua_block {
            local metrics = require("resty.grpc_yar_proxy.metrics")
            local hooks = metrics.metrics_recorder()
            ngx.ctx.grpc_service = "Calculator"
            hooks.on_request("add", {1, 2})
            hooks.on_response("add", 42, nil)
            local dict = ngx.shared["grpc_yar_proxy_metrics"]
            local keys = dict:get_keys(0)
            -- Should have total counter, ok counter, histogram buckets, sum, count
            local found_total = false
            local found_ok = false
            for _, k in ipairs(keys) do
                if string.find(k, "calls_total") and string.find(k, "status=\"total\"") then
                    found_total = true
                end
                if string.find(k, "calls_total") and string.find(k, "status=\"ok\"") then
                    found_ok = true
                end
            end
            ngx.say("found_total=" .. tostring(found_total))
            ngx.say("found_ok=" .. tostring(found_ok))
        }
    }
--- request
GET /t
--- response_body
found_total=true
found_ok=true
--- no_error_log
[error]

=== TEST 10: compose — combines hooks with pcall isolation
--- http_config
    lua_package_path ";;";
    lua_shared_dict grpc_yar_proxy_metrics 1m;
--- config
    location /t {
        content_by_lua_block {
            local trace = require("resty.grpc_yar_proxy.trace")
            local bad_hook = {
                on_request = function(method, params)
                    error("intentional error")
                end,
            }
            local good_hook = trace.trace_middleware()
            local composed = trace.compose(bad_hook, good_hook)
            composed.on_request("add", {1, 2})
            ngx.say("rid_set=" .. tostring(ngx.ctx.request_id ~= nil))
        }
    }
--- request
GET /t
--- response_body
rid_set=true
--- error_log
on_request hook 1 error
