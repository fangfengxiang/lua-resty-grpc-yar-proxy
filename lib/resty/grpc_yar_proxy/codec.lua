-- lib/resty/grpc_yar_proxy/codec.lua
-- gRPC 帧编解码：5 字节帧头（1 字节压缩标志 + 4 字节大端长度）+ protobuf payload
-- 复用 lua-yar.Util.pack_u32 / unpack_u32 实现大端 uint32 编解码

local Util = require("yar.util")

local _M = {}

-- gRPC 帧头固定大小：1 字节压缩标志 + 4 字节大端长度
_M.FRAME_HEADER_SIZE = 5

-- 压缩标志常量
_M.COMPRESSION_NONE = 0

--- 解析 gRPC 帧
-- @param body string HTTP/2 请求体
-- @return compressed_flag number|nil  压缩标志（0=未压缩）
-- @return payload string|nil          protobuf payload
-- @return frame_size number|nil       完整帧大小（帧头 + payload）
-- @return err string|nil              错误信息（失败时 compressed_flag 为 nil）
function _M.decode_frame(body)
    if not body or #body == 0 then
        return nil, nil, nil, "empty request body"
    end
    if #body < _M.FRAME_HEADER_SIZE then
        return nil, nil, nil, "incomplete gRPC frame header"
    end

    local compressed_flag = string.byte(body, 1, 1)
    local payload_len     = Util.unpack_u32(body, 2)

    if #body < _M.FRAME_HEADER_SIZE + payload_len then
        return nil, nil, nil, "incomplete gRPC frame payload"
    end

    local payload = string.sub(
        body,
        _M.FRAME_HEADER_SIZE + 1,
        _M.FRAME_HEADER_SIZE + payload_len)

    local frame_size = _M.FRAME_HEADER_SIZE + payload_len

    return compressed_flag, payload, frame_size
end

--- 编码 gRPC 帧
-- @param payload string protobuf payload（可为空字符串）
-- @return string 完整 gRPC 帧（5 字节帧头 + payload）
function _M.encode_frame(payload)
    payload = payload or ""
    local flag = string.char(_M.COMPRESSION_NONE)
    return flag .. Util.pack_u32(#payload) .. payload
end

--- 检测请求体是否包含多个 gRPC 帧（流式模式检测）
-- @param body string HTTP/2 请求体
-- @param first_frame_size number 第一个帧的完整大小
-- @return boolean true 表示存在多个帧（流式模式）
function _M.has_multiple_frames(body, first_frame_size)
    return body ~= nil and #body > first_frame_size
end

return _M
