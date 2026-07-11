-- lib/resty/grpc_yar_proxy/errors.lua
-- gRPC 错误码映射：将 YAR 调用错误、protobuf 编解码错误等映射为标准 gRPC 状态码
-- gRPC 状态码参考：https://grpc.io/docs/guides/status-codes/

local ngx = ngx

local _M = {}

-- gRPC 状态码常量
_M.OK                = 0   -- 成功
_M.NOT_FOUND         = 5   -- 服务未找到
_M.UNIMPLEMENTED     = 12  -- 不支持的模式（流式、压缩）
_M.INTERNAL          = 13  -- 内部错误（protobuf 编解码、协议错误）
_M.UNAVAILABLE       = 14  -- 传输层错误
_M.DEADLINE_EXCEEDED = 4   -- 超时

--- 将 YAR 错误映射为 gRPC 状态码
-- YAR 错误分类（字符串前缀）：
--   "transport: ..."  → UNAVAILABLE (14)
--   "timeout: ..."    → DEADLINE_EXCEEDED (4)
--   "protocol: ..."   → INTERNAL (13)
--   无前缀             → INTERNAL (13)（YAR 服务端业务错误）
-- @param err string YAR 错误信息
-- @return status number gRPC 状态码
-- @return message string grpc-message
function _M.map_yar_error(err)
    if not err or err == "" then
        return _M.INTERNAL, "unknown error"
    end

    -- 检查错误前缀
    if string.find(err, "transport:", 1, true) then
        return _M.UNAVAILABLE, err
    elseif string.find(err, "timeout:", 1, true) then
        return _M.DEADLINE_EXCEEDED, err
    elseif string.find(err, "protocol:", 1, true) then
        return _M.INTERNAL, err
    end

    -- 无已知前缀：YAR 服务端业务错误
    return _M.INTERNAL, err
end

--- 发送 gRPC 错误响应
-- 设置 grpc-status 和 grpc-message 头，不输出 payload
-- @param status number gRPC 状态码
-- @param message string|nil grpc-message
function _M.send_error(status, message)
    ngx.header["content-type"] = "application/grpc"
    ngx.header["grpc-status"]  = tostring(status)
    ngx.header["grpc-message"] = message or ""
    ngx.status = ngx.HTTP_OK  -- gRPC 始终使用 HTTP 200，错误在 trailers 中
    return ngx.exit(ngx.HTTP_OK)
end

--- 发送 gRPC 成功响应
-- 设置 grpc-status:0 trailer，输出 gRPC 帧
-- @param frame string 完整的 gRPC 帧（已由 codec.encode_frame 编码）
function _M.send_ok(frame)
    ngx.header["content-type"] = "application/grpc"
    ngx.header["grpc-status"]  = "0"
    ngx.header["grpc-message"] = ""
    ngx.status = ngx.HTTP_OK
    ngx.print(frame)
    return ngx.exit(ngx.HTTP_OK)
end

return _M
