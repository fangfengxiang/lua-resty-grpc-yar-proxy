-- lib/resty/grpc_yar_proxy/bridge.lua
-- 正向桥接：gRPC → YAR 方向
-- protobuf decode → YAR 请求构造 → YAR 调用 → 响应映射 → protobuf encode
--
-- 纯协议转换函数已提取到 converter.lua（零 ngx.* 依赖，可独立测试）
-- 可观测性 hooks 已拆分到 trace.lua / access_log.lua / metrics.lua

local pb        = require("pb")
local Yar       = require("yar")
local errors    = require("resty.grpc_yar_proxy.errors")
local cb        = require("resty.grpc_yar_proxy.circuit_breaker")
local converter = require("resty.grpc_yar_proxy.converter")
local trace     = require("resty.grpc_yar_proxy.trace")
local access_log = require("resty.grpc_yar_proxy.access_log")
local metrics   = require("resty.grpc_yar_proxy.metrics")

local _M = {}

-- 模块级缓存：YAR Client 实例（service name → Client），persistent 模式跨请求复用
local _client_cache = {}

--- 清空所有模块级缓存（供 init.setup 重新加载时调用）
-- 委托 converter.clear_cache() 清空协议转换缓存 + 清空 client 缓存
function _M.clear_cache()
    converter.clear_cache()
    _client_cache = {}
end

--- 获取或创建 YAR Client 实例（按 service 名缓存，persistent 模式）
-- @param service string gRPC Service 名（用作缓存 key）
-- @param service_config table { url=string, options=table|nil }
-- @return client table YAR Client 实例
-- @return err string|nil 创建失败时的错误信息
local function get_client(service, service_config)
    local cached = _client_cache[service]
    if cached then
        return cached
    end

    local ok_c, client = pcall(Yar.Client.new, service_config.url)
    if not ok_c then
        return nil, "failed to create YAR client: " .. tostring(client)
    end

    -- 浅拷贝用户选项（不修改 _svc_cache 中的缓存对象），以便追加 persistent 默认值
    local opts = {}
    if service_config.options then
        for k, v in pairs(service_config.options) do
            opts[k] = v
        end
    end
    if opts.persistent == nil then
        opts.persistent = true
    end

    -- 注入 hooks：收集 YAR 调用元数据到 ngx.ctx（延迟、错误分类）
    -- 同时集成熔断器记录和可观测性 hooks
    -- hooks 签名：on_request(method, params) / on_response(method, retval, err_obj)
    -- lua-yar 的 run_hook() 内部 pcall 保护，hook 异常不影响主流程
    -- hooks 引用 ngx.ctx 全局 table，per-request 自动隔离，persistent 复用安全
    local url = service_config.url
    local obs_hooks = trace.compose(
        trace.trace_middleware(),
        access_log.access_logger(),
        metrics.metrics_recorder()
    )

    opts.hooks = {
        on_request = function(method, params)
            ngx.ctx.yar_call_start = ngx.now()
            ngx.ctx.yar_method = method
            -- 可观测性 hooks on_request
            if obs_hooks.on_request then
                pcall(obs_hooks.on_request, method, params)
            end
        end,
        on_response = function(method, retval, err_obj)
            local end_time = ngx.now()
            ngx.ctx.yar_call_latency = end_time - (ngx.ctx.yar_call_start or end_time)
            if err_obj then
                ngx.ctx.yar_error_code = err_obj.code or "UNKNOWN"
                -- 熔断器记录失败（仅传输层/超时错误计入）
                cb.record_failure(url, err_obj.code)
            else
                ngx.ctx.yar_error_code = nil
                -- 熔断器记录成功
                cb.record_success(url)
            end
            -- 可观测性 hooks on_response
            if obs_hooks.on_response then
                pcall(obs_hooks.on_response, method, retval, err_obj)
            end
        end,
    }

    local ok_s, serr = pcall(client.set_options, client, opts)
    if not ok_s then
        return nil, "failed to set YAR client options: " .. tostring(serr)
    end

    _client_cache[service] = client
    return client
end

--- 完整管线：pb.decode → extract_params → client:call → map_response → pb.encode
-- @param service string gRPC Service 名
-- @param method string gRPC Method 名
-- @param payload string protobuf 编码的请求 payload
-- @param service_config table { url=string, options=table|nil }
-- @return payload string|nil protobuf 编码的响应 payload
-- @return status number|nil gRPC 状态码（失败时）
-- @return err string|nil 错误信息（失败时）
function _M.handle(service, method, payload, service_config)
    -- 从 converter 获取类型名（带缓存）
    local types = converter.get_type_names(service, method)
    local request_type  = types.request
    local response_type = types.response

    -- 1. protobuf decode 请求
    local ok, decoded = pcall(pb.decode, request_type, payload)
    if not ok then
        return nil, errors.INVALID_ARGUMENT, "protobuf decode failed: " .. tostring(decoded)
    end

    -- 2. 提取位置参数
    local params = converter.extract_params(decoded, request_type)

    -- 3. 获取（缓存的）YAR client 并调用
    -- client:call() 返回 nil, err（结构化 Error 对象），不抛异常
    -- 无需 pcall 包裹——lua-yar 的 call() 内部已捕获所有错误
    local client, cerr = get_client(service, service_config)
    if not client then
        return nil, errors.INTERNAL, cerr
    end

    local yar_method = converter.method_to_yar(method)
    local result, err = client:call(yar_method, params)
    if err then
        local status, msg = errors.map_yar_error(err)
        return nil, status, msg
    end

    -- 4. 映射响应值
    local response_table = converter.map_response(result, response_type)

    -- 5. protobuf encode 响应
    local ok2, response_payload = pcall(pb.encode, response_type, response_table)
    if not ok2 then
        return nil, errors.INTERNAL, "protobuf encode failed: " .. tostring(response_payload)
    end

    return response_payload
end

return _M
