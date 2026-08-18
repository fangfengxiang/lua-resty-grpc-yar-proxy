-- lib/resty/grpc_yar_proxy/errors.lua
-- gRPC 错误码映射：将 YAR 调用错误、protobuf 编解码错误等映射为标准 gRPC 状态码
-- gRPC 状态码参考：https://grpc.io/docs/guides/status-codes/

local ngx = ngx
local Yar = require("yar")

local _M = {}

-- gRPC 状态码常量（参考 https://grpc.io/docs/guides/status-codes/）
_M.OK                 = 0   -- 成功
_M.INVALID_ARGUMENT   = 3   -- 客户端请求参数错误（protobuf decode 失败、路径格式错误）
_M.DEADLINE_EXCEEDED  = 4   -- 超时（deadline 到期）
_M.NOT_FOUND          = 5   -- 服务未找到
_M.PERMISSION_DENIED  = 7   -- 权限不足（预留，供 auth hooks 使用）
_M.UNIMPLEMENTED      = 12  -- 不支持的模式（流式、压缩）
_M.INTERNAL           = 13  -- 内部错误（protobuf encode 失败、协议错误）
_M.UNAVAILABLE        = 14  -- 传输层错误（熔断器打开、连接失败）

-- lua-yar 0.1.0 Error 常量 → gRPC 状态码映射表
local _ERROR_CODE_MAP = {
    [Yar.Error.TRANSPORT]  = _M.UNAVAILABLE,
    [Yar.Error.TIMEOUT]    = _M.DEADLINE_EXCEEDED,
    [Yar.Error.PROTOCOL]   = _M.INTERNAL,
    [Yar.Error.NOT_FOUND]  = _M.NOT_FOUND,
    [Yar.Error.EXCEPTION]  = _M.INTERNAL,
}

--- 将 YAR 错误映射为 gRPC 状态码
-- 优先处理 lua-yar 0.1.0 结构化 Error 对象（table，含 code/message 字段）；
-- 当 err 为 string 时回退到前缀匹配以保持兼容。
-- @param err table|string|nil YAR 错误对象或字符串
-- @return status number gRPC 状态码
-- @return message string grpc-message
---@param err table|string|nil YAR 错误对象或字符串
---@return integer status gRPC 状态码
---@return string message grpc-message
function _M.map_yar_error(err)
    if not err or err == "" then
        return _M.INTERNAL, "unknown error"
    end

    -- 结构化 Error 对象：按 code 常量映射
    if type(err) == "table" and err.code then
        local status = _ERROR_CODE_MAP[err.code] or _M.INTERNAL
        local message = err.message or tostring(err)
        return status, message
    end

    -- 字符串错误：前缀匹配（兼容旧版 lua-yar 与测试 mock）
    if type(err) == "string" then
        if string.find(err, "transport:", 1, true) then
            return _M.UNAVAILABLE, err
        elseif string.find(err, "timeout:", 1, true) then
            return _M.DEADLINE_EXCEEDED, err
        elseif string.find(err, "protocol:", 1, true) then
            return _M.INTERNAL, err
        end
        return _M.INTERNAL, err
    end

    -- 其他类型：兜底
    return _M.INTERNAL, tostring(err)
end

--- 发送 gRPC 错误响应
-- 设置 grpc-status 和 grpc-message 头，不输出 payload
-- gRPC 错误响应是 trailers-only 响应（无 body），grpc-status 放在 headers 中
-- @param status number gRPC 状态码
-- @param message string|nil grpc-message
---@param status integer gRPC 状态码
---@param message? string grpc-message
function _M.send_error(status, message)
    ngx.header["content-type"] = "application/grpc"
    ngx.header["grpc-status"]  = tostring(status)
    ngx.header["grpc-message"] = message or ""
    ngx.status = ngx.HTTP_OK  -- gRPC 始终使用 HTTP 200，错误在 trailers 中
    return ngx.exit(ngx.HTTP_OK)
end

--- 发送 gRPC 成功响应
-- 设置 content-type header，输出 gRPC 帧，grpc-status:0 作为 trailer
-- 注意：OpenResty ngx.header 在 ngx.print 后无法修改（headers 已提交），
-- 因此 grpc-status 放在 headers 中（gRPC 客户端兼容此写法）。
-- 严格的 trailer 实现需要 nginx HTTP/2 模块直接支持，OpenResty API 暂不支持。
-- @param frame string 完整的 gRPC 帧（已由 codec.encode_frame 编码）
---@param frame string 完整的 gRPC 帧（已由 codec.encode_frame 编码）
function _M.send_ok(frame)
    ngx.header["content-type"] = "application/grpc"
    ngx.header["grpc-status"]  = "0"
    ngx.header["grpc-message"] = ""
    ngx.status = ngx.HTTP_OK
    ngx.print(frame)
    return ngx.exit(ngx.HTTP_OK)
end

return _M
