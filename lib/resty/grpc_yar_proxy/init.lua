-- lib/resty/grpc_yar_proxy/init.lua
-- lua-resty-grpc-yar-proxy: gRPC → YAR 协议代理 OPM 包入口
--
-- 在 init_by_lua_block 阶段调用 setup(opts) 一次，完成：
--   1. 加载预编译 .pb 二进制描述符（pb.load）
--   2. 存储 services（服务名 → { proto, url, options }）
--   3. 注入 cosocket（Yar.Client.set_socket(ngx.socket)）
--   4. 配置 YAR 默认选项
--
-- 在 content_by_lua_block 阶段调用 serve()，处理单个 gRPC 请求：
--   读取请求体 → 解析 gRPC 帧 → 解析 path → 查 services → bridge.handle → 输出响应

local ngx       = ngx
local pb        = require("pb")
local Yar       = require("yar")
local codec     = require("resty.grpc_yar_proxy.codec")
local bridge    = require("resty.grpc_yar_proxy.bridge")
local converter = require("resty.grpc_yar_proxy.converter")
local errors    = require("resty.grpc_yar_proxy.errors")
local deadline  = require("resty.grpc_yar_proxy.deadline")
local cb        = require("resty.grpc_yar_proxy.circuit_breaker")
local trace     = require("resty.grpc_yar_proxy.trace")
local log = require("resty.grpc_yar_proxy.log")

local _M = {}
_M.VERSION = "0.2.0"

-- 模块级状态
-- Module-level state
local _services    = {}  -- 服务名 → { url=, options= }
local _yar_options = {}
local _svc_cache   = {}  -- 解析后的服务配置缓存（service name → {url, options}）

-- lua-yar Log 级别 → ngx.log 常量映射
-- lua-yar 有 DEBUG(1)/INFO(2)/WARN(3)/ERROR(4)，nginx 无 DEBUG 级别，映射到 INFO
local _NGX_LEVEL_MAP = {
    [Yar.Log.DEBUG] = ngx.INFO,
    [Yar.Log.INFO]  = ngx.INFO,
    [Yar.Log.WARN]  = ngx.WARN,
    [Yar.Log.ERROR] = ngx.ERR,
}

--- 递归合并：table key 递归合并，非 table key 直接覆盖
-- 对齐 lua-yar client.lua 的 deep_merge 语义（含 depth > 100 防护）
-- @param target table 目标 table（原地修改）
-- @param source table 源 table
-- @param depth number 当前递归深度（内部使用）
-- @return table 合并后的 target
local function deep_merge(target, source, depth)
    depth = depth or 0
    if depth > 100 then return target end
    for k, v in pairs(source) do
        if type(v) == "table" and type(target[k]) == "table" then
            deep_merge(target[k], v, depth + 1)
        else
            target[k] = v
        end
    end
    return target
end

--- 加载 .pb 二进制描述符文件
-- @param file string 文件路径
-- @return boolean 成功
-- @return err string|nil 错误信息
local function load_pb_file(file)
    local f, err = io.open(file, "rb")
    if not f then
        return false, "cannot open proto file: " .. file .. " (" .. (err or "unknown") .. ")"
    end
    local data = f:read("*a")
    f:close()

    if not data or #data == 0 then
        return false, "empty proto file: " .. file
    end

    local ok, perr = pcall(pb.load, data)
    if not ok then
        return false, "failed to load " .. file .. ": " .. tostring(perr)
    end
    return true
end

--- 初始化：加载 .pb 文件、配置 services、注入 cosocket
-- 在 init_by_lua_block 中调用一次
-- @param opts table 配置选项
--   services  = {                                  -- 服务配置（proto + endpoint 合一）
--       Calculator = {
--           proto   = "proto/calc.pb",              -- .pb 文件路径
--           url     = "http://127.0.0.1:8888/api",  -- YAR Server URL
--           options = { timeout = 5000 },           -- 可选，per-service 覆盖
--       },
--       UserService = { proto = "...", url = "..." },
--   }
--   yar_options  = { timeout = 3000, ... }  -- YAR client 全局默认选项
-- @return _M self
---@param opts table { services:table, yar_options:table, circuit_breaker:table }
---@return table self
function _M.setup(opts)
    opts = opts or {}

    -- 0. 清空缓存（支持重复初始化：测试、热加载）
    bridge.clear_cache()
    _svc_cache = {}

    -- 1. 解析 services：加载 .pb 文件 + 存储 endpoint 配置
    local services = opts.services
    if type(services) ~= "table" or next(services) == nil then
        error("grpc_yar_proxy: services is required and must be a non-empty table", 0)
    end

    local loaded_files = {}  -- 去重：同一 .pb 文件只加载一次

    _services = {}
    for service_name, svc_config in pairs(services) do
        if type(svc_config) ~= "table" then
            error("grpc_yar_proxy: service config for '" .. service_name .. "' must be a table", 0)
        end

        -- 加载 .pb 文件（去重）
        local proto_file = svc_config.proto
        if not proto_file or type(proto_file) ~= "string" then
            error("grpc_yar_proxy: service '" .. service_name .. "' is missing or has invalid 'proto' field", 0)
        end
        if not loaded_files[proto_file] then
            local ok, err = load_pb_file(proto_file)
            if not ok then
                error("grpc_yar_proxy: " .. err, 0)
            end
            loaded_files[proto_file] = true
        end

        -- 校验 url
        local url = svc_config.url
        if not url or type(url) ~= "string" then
            error("grpc_yar_proxy: service '" .. service_name .. "' is missing or has invalid 'url' field", 0)
        end

        -- 校验 options（可选，但若提供则必须为 table）
        local svc_opts = svc_config.options
        if svc_opts ~= nil and type(svc_opts) ~= "table" then
            error("grpc_yar_proxy: service '" .. service_name .. "' options must be a table", 0)
        end

        _services[service_name] = {
            url     = url,
            options = svc_opts,
        }
    end

    -- 2. 存储 YAR 默认选项
    _yar_options = opts.yar_options or {}

    -- 3. 注入 cosocket（出向 YAR 调用走 OpenResty 非阻塞 I/O）
    Yar.Client.set_socket(ngx.socket)

    -- 4. 注入 Log writer：将 lua-yar 内部日志路由到 ngx.log
    Yar.Log.set_writer(function(lvl, msg)
        ngx.log(_NGX_LEVEL_MAP[lvl] or ngx.ERR, "yar: " .. msg)
    end)

    -- 5. 设置日志级别（默认 WARN，与 lua-yar 自身默认一致）
    Yar.Log.set_level(opts.log_level or Yar.Log.WARN)

    -- 6. 初始化熔断器
    cb.init(opts.circuit_breaker)

    return _M
end

--- 解析服务配置为最终 YAR 调用参数（合并全局默认 + per-service 覆盖）
-- @param service_name string 服务名（用作缓存 key）
-- @return url string YAR Server URL
-- @return opts table 合并后的 YAR 选项
local function resolve_service_config(service_name)
    -- 从缓存获取已解析的配置
    local cached = _svc_cache[service_name]
    if cached then
        return cached.url, cached.options
    end

    local svc = _services[service_name]
    if not svc then
        return nil, nil
    end

    -- 合并全局默认 + per-service 覆盖（deep_merge 正确处理嵌套子组如 keepalive）
    local opts = {}
    deep_merge(opts, _yar_options)
    if svc.options then
        deep_merge(opts, svc.options)
    end

    _svc_cache[service_name] = { url = svc.url, options = opts }
    return svc.url, opts
end

--- 处理单个 gRPC 请求（在 content_by_lua_block 中调用）
-- 读取请求体 → 解析 gRPC 帧 → 检测流式 → 解析 path → 查 services → bridge.handle → 输出响应
function _M.serve()  --luacheck: no unused args
    -- 0. 记录请求开始时间，解析 deadline
    local request_start = ngx.now()
    local deadline_ms = deadline.parse_timeout(ngx.var.http_grpc_timeout)
    ngx.ctx.request_start = request_start
    ngx.ctx.grpc_deadline_ms = deadline_ms

    -- 0a. 生成/提取请求 ID（委托给 trace 模块，消除内联重复）
    trace.ensure_request_id("x-request-id")

    -- 0b. 前置 deadline 检查
    if deadline.check_front(deadline_ms, request_start) then
        ngx.ctx.grpc_status = errors.DEADLINE_EXCEEDED
        errors.send_error(errors.DEADLINE_EXCEEDED, "deadline already exceeded")
        return
    end

    -- 1. 读取请求体
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        -- 请求体可能被写入临时文件（body spill）
        local file = ngx.req.get_body_file()
        if file then
            ngx.log(ngx.WARN, "request body spilled to disk: " .. file)
            local f = io.open(file, "rb")
            if f then
                body = f:read("*a")
                f:close()
            end
        end
    end

    -- 2. 解析 gRPC 帧
    local flag, payload, frame_size, err = codec.decode_frame(body)
    if not flag then
        ngx.ctx.grpc_status = errors.INVALID_ARGUMENT
        errors.send_error(errors.INVALID_ARGUMENT, err)
        return
    end

    -- 3. 压缩标志检查
    if flag ~= codec.COMPRESSION_NONE then
        ngx.ctx.grpc_status = errors.UNIMPLEMENTED
        errors.send_error(errors.UNIMPLEMENTED, "compression not supported")
        return
    end

    -- 4. 流式模式检测（多帧 = streaming）
    if codec.has_multiple_frames(body, frame_size) then
        ngx.ctx.grpc_status = errors.UNIMPLEMENTED
        errors.send_error(errors.UNIMPLEMENTED, "streaming mode not supported")
        return
    end

    -- 5. 解析 gRPC path
    local path = ngx.var.uri
    local service, method, perr = converter.parse_grpc_path(path)
    if not service then
        ngx.ctx.grpc_status = errors.INVALID_ARGUMENT
        errors.send_error(errors.INVALID_ARGUMENT, perr)
        return
    end

    -- 写入请求元数据到 ngx.ctx（供 log_by_lua 阶段读取）
    ngx.ctx.grpc_service = service
    ngx.ctx.grpc_method = method

    -- 6. 查 services
    local url, svc_opts = resolve_service_config(service)
    if not url then
        ngx.ctx.grpc_status = errors.NOT_FOUND
        errors.send_error(errors.NOT_FOUND, "service not found: " .. service)
        return
    end

    -- 6a. 熔断器检查
    if not cb.allow(url) then
        ngx.ctx.grpc_status = errors.UNAVAILABLE
        errors.send_error(errors.UNAVAILABLE, "circuit breaker open: " .. url)
        return
    end

    -- 7. 调用 bridge.handle（完整管线，pcall 防止未预期异常逃逸）
    local ok, response_payload, status, errmsg = pcall(bridge.handle, service, method, payload, {
        url     = url,
        options = svc_opts,
    })
    if not ok then
        ngx.ctx.grpc_status = errors.INTERNAL
        errors.send_error(errors.INTERNAL, "uncaught error: " .. tostring(response_payload))
        return
    end

    if not response_payload then
        ngx.ctx.grpc_status = status or errors.INTERNAL
        errors.send_error(status, errmsg)
        return
    end

    -- 7a. 后置 deadline 检查
    if deadline.check_back(deadline_ms, request_start) then
        ngx.ctx.grpc_status = errors.DEADLINE_EXCEEDED
        errors.send_error(errors.DEADLINE_EXCEEDED, "deadline exceeded after call")
        return
    end

    -- 8. 输出成功响应
    ngx.ctx.grpc_status = errors.OK
    local frame = codec.encode_frame(response_payload)
    errors.send_ok(frame)
end

--- 异步日志阶段（在 log_by_lua_block 中调用）
-- 从 ngx.ctx 读取请求元数据和 YAR 调用元数据，输出结构化日志行
-- 同时调用 log.flush_logs() 输出延迟的访问日志（deferred 模式）
-- 所有字段做 nil 兜底，确保 serve() 未执行时不报错
function _M.log_phase()
    local ctx = ngx.ctx
    local service  = ctx.grpc_service or "-"
    local method   = ctx.grpc_method or "-"
    local status    = ctx.grpc_status or "-"
    local latency   = ctx.yar_call_latency
    local err_code  = ctx.yar_error_code
    local rid       = ctx.request_id or "-"

    local line = string.format("grpc_yar_proxy rid=%s %s/%s status=%s yar_latency_ms=%.3f",
        rid, service, method, tostring(status),
        latency and latency * 1000 or 0)
    if err_code then
        line = line .. " yar_error=" .. tostring(err_code)
    end
    ngx.log(ngx.INFO, line)

    -- 输出延迟的访问日志（deferred 模式，无 entry 时静默返回）
    log.flush_logs()
end

return _M
