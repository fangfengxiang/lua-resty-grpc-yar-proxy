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

local ngx    = ngx
local pb     = require("pb")
local Yar    = require("yar")
local codec  = require("resty.grpc_yar_proxy.codec")
local bridge = require("resty.grpc_yar_proxy.bridge")
local errors = require("resty.grpc_yar_proxy.errors")

local _M = {}
_M.VERSION = "0.1.0"

-- 模块级状态
local _services    = {}  -- 服务名 → { url=, options= }
local _yar_options = {}
local _svc_cache   = {}  -- 解析后的服务配置缓存（service name → {url, options}）

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

    -- 合并全局默认 + per-service 覆盖
    local opts = {}
    for k, v in pairs(_yar_options) do
        opts[k] = v
    end
    if svc.options then
        for k, v in pairs(svc.options) do
            opts[k] = v
        end
    end

    _svc_cache[service_name] = { url = svc.url, options = opts }
    return svc.url, opts
end

--- 处理单个 gRPC 请求（在 content_by_lua_block 中调用）
-- 读取请求体 → 解析 gRPC 帧 → 检测流式 → 解析 path → 查 services → bridge.handle → 输出响应
function _M.serve()
    -- 1. 读取请求体
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        -- 请求体可能被写入临时文件
        local file = ngx.req.get_body_file()
        if file then
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
        errors.send_error(errors.INTERNAL, err)
        return
    end

    -- 3. 压缩标志检查
    if flag ~= codec.COMPRESSION_NONE then
        errors.send_error(errors.UNIMPLEMENTED, "compression not supported")
        return
    end

    -- 4. 流式模式检测（多帧 = streaming）
    if codec.has_multiple_frames(body, frame_size) then
        errors.send_error(errors.UNIMPLEMENTED, "streaming mode not supported")
        return
    end

    -- 5. 解析 gRPC path
    local path = ngx.var.uri
    local service, method, perr = bridge.parse_grpc_path(path)
    if not service then
        errors.send_error(errors.INTERNAL, perr)
        return
    end

    -- 6. 查 services
    local url, svc_opts = resolve_service_config(service)
    if not url then
        errors.send_error(errors.NOT_FOUND, "service not found: " .. service)
        return
    end

    -- 7. 调用 bridge.handle（完整管线，pcall 防止未预期异常逃逸）
    local ok, response_payload, status, errmsg = pcall(bridge.handle, service, method, payload, {
        url     = url,
        options = svc_opts,
    })
    if not ok then
        errors.send_error(errors.INTERNAL, "uncaught error: " .. tostring(response_payload))
        return
    end

    if not response_payload then
        errors.send_error(status, errmsg)
        return
    end

    -- 8. 输出成功响应
    local frame = codec.encode_frame(response_payload)
    errors.send_ok(frame)
end

return _M
