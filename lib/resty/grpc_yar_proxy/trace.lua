-- lib/resty/grpc_yar_proxy/trace.lua
-- 请求 ID 管理 + hooks 组合 + 错误状态提取
-- 可观测性基础模块，被 log.lua 和 metrics.lua 依赖
--
-- 从 observability.lua 拆出：
--   gen_request_id()              — 多熵源混合生成 request ID
--   get_request_id_from_header()  — 从 HTTP header 提取或生成 ID
--   get_or_create_request_id()    — 从 platform.ctx 读取或创建 ID
--   get_request_id()              — 公开 API：获取当前请求 ID
--   ensure_request_id()           — 公开 API：确保 ID 存在（serve 阶段调用）
--   trace_middleware()             — hooks 工厂：生成/提取请求 ID
--   compose()                      — 组合多个 hooks，pcall 隔离
--   error_status()                — 从 Error 对象提取错误状态字符串
--
-- 共享 ctx key（log 和 metrics 共用）：
--   CTX_START_TIME — 请求开始时间戳

local platform = require("resty.grpc_yar_proxy.platform")
local pcall = pcall
local type = type
local pairs = pairs
local tostring = tostring
local string = string

local _M = {}

-- 共享 ctx key：请求开始时间（access_logger on_request 写，metrics_recorder on_response 读）
_M.CTX_START_TIME = "grpc_yar_obs_start_time"

-- 模块级请求 ID 计数器（多熵源之一，per-worker）
-- Module-level request ID counter (one of multi-entropy sources)
local request_seq = 0

--- 生成 request ID（多熵源混合，per-worker 唯一）
-- 熵源：platform.time（秒级时间）+ platform.worker_pid（进程区分）+ 计数器（进程内单调递增）
-- 对标 lua-yar default_gen_id 设计，但不调用 math.randomseed（库不越权播种）
-- @return string request ID（16 进制字符串，便于日志阅读）
local function gen_request_id()
    request_seq = request_seq + 1
    local t = platform.time() or 0
    local pid = platform.worker_pid() or 0
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
    local rid = platform.var[var_name]
    if rid and rid ~= "" then
        return rid
    end
    return gen_request_id()
end

--- 获取或创建 request ID（从 platform.ctx 读取，不存在则生成并注入）
-- @return string request ID
local function get_or_create_request_id()
    local ctx = platform.ctx
    if ctx.request_id then
        return ctx.request_id
    end
    local id = gen_request_id()
    ctx.request_id = id
    return id
end

-- 导出内部函数供 log.lua 使用
_M.get_or_create_request_id = get_or_create_request_id

--- 从 Error 对象提取错误状态字符串
-- @param err_obj table|nil Error 对象（含 code 字段）
-- @return string 错误状态（"ok" / "transport" / "timeout" / "protocol" / "not_found" / "exception" / "unknown"）
function _M.error_status(err_obj)
    if not err_obj then return "ok" end
    local code = err_obj.code or "unknown"
    return string.lower(code)
end

--- 获取当前请求的 request ID（公开 API）
-- 供业务代码或日志格式化使用，从 platform.ctx 读取或生成
---@return string request ID
function _M.get_request_id()
    return get_or_create_request_id()
end

--- 确保请求 ID 存在（从 header 提取或生成），供 serve() 阶段直接调用
-- 在 YAR hooks 触发前就需要 request ID 的场景使用
---@param header_name? string 请求 ID header 名（默认 "x-request-id"）
---@return string request ID
function _M.ensure_request_id(header_name)
    local ctx = platform.ctx
    if not ctx.request_id then
        ctx.request_id = get_request_id_from_header(header_name)
    end
    return ctx.request_id
end

--- 创建 trace 中间件 hooks 工厂
-- 生成/提取请求 ID，存入 platform.ctx.request_id
---@param opts? table { header_name = "x-request-id", id_generator = fun():string }
---@return table hooks { on_request = fun(method:string, params:any) }
function _M.trace_middleware(opts)
    opts = opts or {}
    local header_name = opts.header_name or "x-request-id"
    local id_gen = opts.id_generator

    return {
        on_request = function(_method, _params)
            local ctx = platform.ctx
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
                        platform.log(platform.LOG_WARN, "[grpc_yar_proxy] on_request hook "
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
                        platform.log(platform.LOG_WARN, "[grpc_yar_proxy] on_response hook "
                            .. i .. " error: " .. tostring(err))
                    end
                end
            end
        end,
    }
end

return _M
