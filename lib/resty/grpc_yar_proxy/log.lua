-- lib/resty/grpc_yar_proxy/log.lua
-- 结构化 JSON 访问日志 + 延迟日志输出
-- 从 observability.lua 拆出，依赖 trace.lua 的 error_status / get_or_create_request_id / CTX_START_TIME
--
-- 函数：
--   to_json(t)           — 零依赖简易 JSON 序列化（扁平 table）
--   estimate_size(v)     — 计算值大小（用于 params_size / retval_size）
--   access_logger(opts)   — hooks 工厂：结构化 JSON 访问日志（支持 deferred 模式）
--   flush_logs(opts)      — 在 log_by_lua 阶段输出延迟日志

local ngx = ngx
local type = type
local pairs = pairs
local tostring = tostring
local string = string
local math = math
local table = table

local trace = require("resty.grpc_yar_proxy.trace")
local error_status = trace.error_status
local get_or_create_request_id = trace.get_or_create_request_id
local CTX_START_TIME = trace.CTX_START_TIME

local _M = {}

-- 仅 log 使用的 ctx key
local CTX_PARAMS_SIZE = "grpc_yar_obs_params_size"
-- 延迟日志模式：on_response 组装 entry 存到此 key，由 flush_logs() 在 log_by_lua 阶段输出
local CTX_LOG_ENTRY = "grpc_yar_obs_log_entry"

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
--   init_by_lua:      hooks = log.access_logger({ defer = true })
--   log_by_lua_block: require("resty.grpc_yar_proxy.log").flush_logs()
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

return _M
