-- lib/resty/grpc_yar_proxy/observability.lua
-- 可观测性模块：请求 ID、结构化访问日志、指标记录
-- Observability: request ID, structured access log, metrics recording
--
-- 参考 lua-resty-yar observability.lua 的可组合 hooks 工厂模式：
--   access_logger()     — 结构化 JSON 访问日志（支持 deferred 模式）
--   trace_middleware()  — 请求 ID 生成/提取
--   metrics_recorder()  — ngx.shared.DICT 计数器 + 延迟直方图 + Prometheus export
--   compose()           — 组合多个 hooks，pcall 隔离
--   flush_logs()        — 在 log_by_lua 阶段输出延迟日志
--   get_request_id()   — 获取当前请求 ID（公开 API）
--
-- 设计原则：
--   1. hooks 工厂返回 { on_request, on_response } 表，与 lua-yar hooks 接口对齐
--   2. compose() 合并多个 hooks，每个 hook 独立 pcall 保护
--   3. 指标存储在 ngx.shared.DICT，跨 worker 可见
--   4. 无 shared dict 时静默降级（不报错，仅不记录指标）
--   5. deferred 模式将日志 I/O 移出响应热路径，对标 nginx access_log 的 log phase 语义

local ngx = ngx
local pcall = pcall
local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local string = string
local math = math
local table = table

local _M = {}
_M.VERSION = "0.2.0"

-- 延迟直方图桶边界（毫秒），对标 Prometheus histogram 默认 bucket
-- Latency histogram bucket boundaries (milliseconds)
local LATENCY_BUCKETS = { 1, 5, 10, 50, 100, 500, 1000, 5000 }

-- 模块级请求 ID 计数器（多熵源之一，per-worker）
-- Module-level request ID counter (one of multi-entropy sources)
local request_seq = 0

-- ngx.ctx 中的字段名（access_logger 和 metrics_recorder 共享）
local CTX_START_TIME = "grpc_yar_obs_start_time"
local CTX_PARAMS_SIZE = "grpc_yar_obs_params_size"
-- 延迟日志模式：on_response 组装 entry 存到此 key，由 flush_logs() 在 log_by_lua 阶段输出
local CTX_LOG_ENTRY = "grpc_yar_obs_log_entry"

--- 生成 request ID（多熵源混合，per-worker 唯一）
-- 熵源：ngx.time（秒级时间）+ ngx.worker.pid（进程区分）+ 计数器（进程内单调递增）
-- 对标 lua-yar default_gen_id 设计，但不调用 math.randomseed（库不越权播种）
-- @return string request ID（16 进制字符串，便于日志阅读）
local function gen_request_id()
    request_seq = request_seq + 1
    local t = ngx.time() or 0
    local pid = ngx.worker.pid() or 0
    local id = (t * 1000000 + pid * 10000 + request_seq) % 0x100000000
    return string.format("%08x", id)
end

--- 从 header 提取或生成请求 ID
-- Extract or generate request ID from HTTP header
-- @param header_name string 请求 ID header 名（默认 "x-request-id"）
-- @return string request ID
local function get_request_id_from_header(header_name)
    header_name = header_name or "x-request-id"
    local var_name = "http_" .. header_name:gsub("-", "_")
    local rid = ngx.var[var_name]
    if rid and rid ~= "" then
        return rid
    end
    return gen_request_id()
end

--- 获取或创建 request ID（从 ngx.ctx 读取，不存在则生成并注入）
-- @return string request ID
local function get_or_create_request_id()
    local ctx = ngx.ctx
    if ctx.request_id then
        return ctx.request_id
    end
    local id = gen_request_id()
    ctx.request_id = id
    return id
end

--- 简易 JSON 序列化（零依赖，不依赖 cjson）
-- 仅支持扁平 table（string/number/boolean/nil 值），足够访问日志使用
-- @param t table 待序列化的表
-- @return string JSON 字符串
local function to_json(t)
    local parts = {}
    for k, v in pairs(t) do
        local val
        local tv = type(v)
        if tv == "string" then
            local s = string.gsub(v, '\\', '\\\\')
            s = string.gsub(s, '"', '\\"')
            s = string.gsub(s, '\n', '\\n')
            s = string.gsub(s, '\r', '\\r')
            s = string.gsub(s, '\t', '\\t')
            val = '"' .. s .. '"'
        elseif tv == "number" then
            val = tostring(v)
        elseif tv == "boolean" then
            val = v and "true" or "false"
        elseif v == nil then
            val = "null"
        else
            val = '"' .. tostring(v) .. '"'
        end
        parts[#parts + 1] = '"' .. k .. '":' .. val
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

--- 计算表/值的"大小"（用于 params_size / retval_size 日志字段）
-- @param v any 值
-- @return number 大小（数组长度，或字符串长度，或 0）
local function estimate_size(v)
    if v == nil then return 0 end
    local tv = type(v)
    if tv == "table" then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        return n
    elseif tv == "string" then
        return #v
    end
    return 1
end

--- 从 Error 对象提取错误状态字符串
-- @param err_obj table|nil Error 对象（含 code 字段）
-- @return string 错误状态（"ok" / "transport" / "timeout" / "protocol" / "not_found" / "exception" / "unknown"）
local function error_status(err_obj)
    if not err_obj then return "ok" end
    local code = err_obj.code or "unknown"
    return string.lower(code)
end

--- 获取当前请求的 request ID（公开 API）
-- 供业务代码或日志格式化使用，从 ngx.ctx 读取或生成
---@return string request ID
function _M.get_request_id()
    return get_or_create_request_id()
end

--- 确保请求 ID 存在（从 header 提取或生成），供 serve() 阶段直接调用
-- 在 YAR hooks 触发前就需要 request ID 的场景使用
---@param header_name? string 请求 ID header 名（默认 "x-request-id"）
---@return string request ID
function _M.ensure_request_id(header_name)
    local ctx = ngx.ctx
    if not ctx.request_id then
        ctx.request_id = get_request_id_from_header(header_name)
    end
    return ctx.request_id
end

--- 创建 trace 中间件 hooks 工厂
-- 生成/提取请求 ID，存入 ngx.ctx.request_id
---@param opts? table { header_name = "x-request-id", id_generator = fun():string }
---@return table hooks { on_request = fun(method:string, params:any) }
function _M.trace_middleware(opts)
    opts = opts or {}
    local header_name = opts.header_name or "x-request-id"
    local id_gen = opts.id_generator

    return {
        on_request = function(_method, _params)
            local ctx = ngx.ctx
            if not ctx.request_id then
                if id_gen then
                    ctx.request_id = id_gen()
                else
                    ctx.request_id = get_request_id_from_header(header_name)
                end
            end
        end,
    }
end

--- 创建访问日志 hooks 工厂（结构化 JSON）
-- on_request 记录开始时间和参数大小，on_response 计算 duration 并组装日志 entry
--
-- 输出模式（opts.defer）：
--   false/nil（默认）：on_response 立即输出 JSON 日志（in-request，响应热路径内）
--   true：on_response 仅将 entry 存到 ngx.ctx，由 flush_logs() 在 log_by_lua 阶段输出
--         日志 I/O 移出响应热路径，对标 nginx access_log 的 log phase 语义
--
-- @param opts table|nil { level = ngx.INFO, defer = boolean, writer = fn(level, msg) }
-- @return table hooks { on_request, on_response }
---@param opts? table { level:integer, defer:boolean, writer:fun(level:integer,msg:string) }
---@return table hooks { on_request:fun, on_response:fun }
function _M.access_logger(opts)
    opts = opts or {}
    local level = opts.level or ngx.INFO
    local defer = opts.defer
    local writer = opts.writer

    return {
        on_request = function(_method, params)
            local ctx = ngx.ctx
            ctx[CTX_START_TIME] = ngx.now()
            ctx[CTX_PARAMS_SIZE] = estimate_size(params)
        end,
        on_response = function(method, retval, err_obj)
            local start = ngx.ctx[CTX_START_TIME] or ngx.now()
            local duration_ms = (ngx.now() - start) * 1000
            local status = error_status(err_obj)
            local request_id = get_or_create_request_id()
            local service = ngx.ctx.grpc_service or "unknown"

            local entry = {
                ts           = ngx.localtime(),
                level        = (status == "ok") and "info" or "warn",
                module       = "grpc_yar_proxy",
                service      = service,
                method       = method or "unknown",
                params_size  = ngx.ctx[CTX_PARAMS_SIZE] or 0,
                status       = status,
                duration_ms  = math.floor(duration_ms * 1000) / 1000,
                request_id   = request_id,
            }
            if err_obj then
                entry.error = err_obj.message or ""
            else
                entry.retval_size = estimate_size(retval)
            end

            if defer then
                -- 延迟模式：存到 ngx.ctx，由 flush_logs() 在 log_by_lua 阶段输出
                ngx.ctx[CTX_LOG_ENTRY] = entry
            else
                -- 即时模式：立即输出
                local json = to_json(entry)
                local log_level = (status == "ok") and level or ngx.WARN
                if writer then
                    writer(log_level, json)
                else
                    ngx.log(log_level, json)
                end
            end
        end,
    }
end

--- 在 log_by_lua 阶段输出延迟的访问日志
-- 配合 access_logger({ defer = true }) 使用：
--   init_by_lua:      hooks = obs.access_logger({ defer = true })
--   log_by_lua_block: require("resty.grpc_yar_proxy.observability").flush_logs()
-- 从 ngx.ctx 读取 on_response 组装的 entry 并输出。
-- 若 entry 不存在（非 RPC 请求或未配置 defer 模式），静默返回。
-- @param opts table|nil { writer = fn(level, msg) }，默认 ngx.log(ngx.INFO, ...)
---@param opts? table { writer:fun(level:integer,msg:string) }
function _M.flush_logs(opts)
    opts = opts or {}
    local writer = opts.writer

    local entry = ngx.ctx[CTX_LOG_ENTRY]
    if not entry then
        return
    end
    local json = to_json(entry)
    local level = (entry.status == "ok") and ngx.INFO or ngx.WARN
    if writer then
        writer(level, json)
    else
        ngx.log(level, json)
    end
end

--- 创建指标记录 hooks 工厂
-- 在 on_response 中记录请求计数和延迟直方图到 ngx.shared.DICT
-- 支持通过 export() 导出 Prometheus exposition format
-- @param opts table|nil { dict_name = "grpc_yar_proxy_metrics", prefix = "grpc_yar" }
-- @return table hooks { on_request, on_response, export }
---@param opts? table { dict_name:string, prefix:string }
---@return table hooks { on_request:fun, on_response:fun, export:fun():string }
function _M.metrics_recorder(opts)
    opts = opts or {}
    local dict_name = opts.dict_name or "grpc_yar_proxy_metrics"
    local prefix = opts.prefix or "grpc_yar"

    local function get_dict()
        local ok, dict = pcall(function()
            return ngx.shared[dict_name]
        end)
        if ok and dict then
            return dict
        end
        return nil
    end

    local dict = get_dict()
    if not dict then
        ngx.log(ngx.WARN, "[grpc_yar_proxy observability] shared dict '" .. dict_name
            .. "' not found, metrics disabled. Add 'lua_shared_dict " .. dict_name
            .. " 1m;' to nginx.conf")
        return {
            on_request = function() end,
            on_response = function() end,
            export = function() return "" end,
        }
    end

    local function counter_key(service, method, kind)
        return prefix .. "_calls_total{service=\"" .. service
            .. "\",method=\"" .. method .. "\",status=\"" .. kind .. "\"}"
    end

    local function bucket_key(service, method, bucket_idx)
        return prefix .. "_duration_bucket{service=\"" .. service
            .. "\",method=\"" .. method .. "\",le=\"" .. LATENCY_BUCKETS[bucket_idx] .. "\"}"
    end

    local function sum_key(service, method)
        return prefix .. "_duration_sum{service=\"" .. service
            .. "\",method=\"" .. method .. "\"}"
    end

    local function count_key(service, method)
        return prefix .. "_duration_count{service=\"" .. service
            .. "\",method=\"" .. method .. "\"}"
    end

    local function record(method, _retval, err_obj)
        local start = ngx.ctx[CTX_START_TIME] or ngx.now()
        local duration_ms = (ngx.now() - start) * 1000
        local status = error_status(err_obj)
        local service = ngx.ctx.grpc_service or "unknown"

        -- 计数器（incr，原子操作）
        local _, cerr = dict:incr(counter_key(service, method, "total"), 1, 0)
        if cerr then
            ngx.log(ngx.WARN, "[grpc_yar_proxy observability] incr error: " .. tostring(cerr))
        end
        dict:incr(counter_key(service, method, status), 1, 0)

        -- 直方图：找到对应 bucket
        local bucket_idx = #LATENCY_BUCKETS
        for i = 1, #LATENCY_BUCKETS do
            if duration_ms <= LATENCY_BUCKETS[i] then
                bucket_idx = i
                break
            end
        end
        -- 累积直方图：bucket[i] 包含所有 <= LATENCY_BUCKETS[i] 的计数
        for i = 1, bucket_idx do
            dict:incr(bucket_key(service, method, i), 1, 0)
        end
        -- +Inf bucket
        dict:incr(prefix .. "_duration_bucket{service=\"" .. service
            .. "\",method=\"" .. method .. "\",le=\"+Inf\"}", 1, 0)

        -- sum 和 count
        dict:incr(sum_key(service, method), duration_ms, 0)
        dict:incr(count_key(service, method), 1, 0)
    end

    return {
        on_request = function(_method, _params)
            ngx.ctx[CTX_START_TIME] = ngx.now()
        end,
        on_response = function(method, retval, err_obj)
            record(method, retval, err_obj)
        end,
        --- 导出 Prometheus 文本格式
        -- 仅导出以 prefix 开头的 key，过滤共享 dict 中其他模块的数据
        -- @return string Prometheus exposition format
        export = function()
            local keys = dict:get_keys(0)
            local lines = {}

            for _, key in ipairs(keys) do
                if type(key) == "string" and #key > 0
                   and string.sub(key, 1, #prefix) == prefix then
                    local val = dict:get(key) or 0
                    lines[#lines + 1] = key .. " " .. tostring(val)
                end
            end

            return table.concat(lines, "\n") .. "\n"
        end,
    }
end

--- 组合多个 hooks，每个 hook 独立 pcall 保护
-- 任一 hook 异常不影响其他 hook 和主流程
-- 对标 lua-yar 服务端 handler pcall 隔离模式
-- @param ... table hooks 表（每个含 on_request/on_response）
-- @return table 合并后的 hooks { on_request, on_response }
---@param ... table hooks 表（每个含 on_request/on_response）
---@return table hooks { on_request:fun, on_response:fun }
function _M.compose(...)
    local hooks_list = {}
    for i = 1, select("#", ...) do
        local h = select(i, ...)
        if h then
            hooks_list[#hooks_list + 1] = h
        end
    end

    if #hooks_list == 0 then
        return {}
    end

    return {
        on_request = function(method, params)
            for i = 1, #hooks_list do
                local fn = hooks_list[i].on_request
                if fn then
                    local ok, err = pcall(fn, method, params)
                    if not ok then
                        ngx.log(ngx.WARN, "[grpc_yar_proxy observability] on_request hook "
                            .. i .. " error: " .. tostring(err))
                    end
                end
            end
        end,
        on_response = function(method, retval, err_obj)
            for i = 1, #hooks_list do
                local fn = hooks_list[i].on_response
                if fn then
                    local ok, err = pcall(fn, method, retval, err_obj)
                    if not ok then
                        ngx.log(ngx.WARN, "[grpc_yar_proxy observability] on_response hook "
                            .. i .. " error: " .. tostring(err))
                    end
                end
            end
        end,
    }
end

_M._LATENCY_BUCKETS = LATENCY_BUCKETS

return _M
