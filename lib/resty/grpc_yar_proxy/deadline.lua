-- lib/resty/grpc_yar_proxy/deadline.lua
-- gRPC deadline 解析与检查
-- gRPC deadline parsing and checking
--
-- 参考 gRPC over HTTP/2 协议规范：
-- https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md
--
-- grpc-timeout header 格式：<value><unit>
-- unit 取值：H(时) M(分) S(秒) m(毫秒) u(微秒) n(纳秒)
--
-- 设计决策：deadline 不修改 YAR Client timeout（persistent 模式无法 per-request set_options），
-- 仅做前后检查：前置检查在 serve 入口，后置检查在 YAR 调用返回后。

local platform = require("resty.grpc_yar_proxy.platform")

local _M = {}
_M.VERSION = "0.1.0"

-- grpc-timeout 单位 → 毫秒乘数
-- grpc-timeout unit → millisecond multiplier
local _UNIT_MULTIPLIERS = {
    H = 3600 * 1000,   -- hours → ms
    M = 60 * 1000,     -- minutes → ms
    S = 1000,          -- seconds → ms
    m = 1,             -- milliseconds → ms
    u = 0.001,         -- microseconds → ms
    n = 0.000001,      -- nanoseconds → ms
}

--- 解析 grpc-timeout header 值为毫秒数
-- Parse grpc-timeout header value to milliseconds
-- @param header string|nil grpc-timeout header 值（如 "100m", "5S", "1H"）
-- @return number|nil 毫秒数，header 缺失或格式非法时返回 nil
function _M.parse_timeout(header)
    if not header or header == "" then
        return nil
    end
    local value, unit = header:match("^(%d+)([HMSmun])$")
    if not value then
        return nil
    end
    local multiplier = _UNIT_MULTIPLIERS[unit]
    if not multiplier then
        return nil
    end
    return tonumber(value) * multiplier
end

--- 检查 deadline 是否已过期
-- Check whether deadline has expired
-- 前置检查和后置检查语义相同：elapsed >= deadline
-- @param deadline_ms number|nil deadline 毫秒数
-- @param request_start number 请求开始时间（platform.now()）
-- @return boolean true 表示 deadline 已过期
function _M.check_expired(deadline_ms, request_start)
    if not deadline_ms or not request_start then
        return false
    end
    local elapsed_ms = (platform.now() - request_start) * 1000
    return elapsed_ms >= deadline_ms
end

--- 前置检查：deadline 是否已过期（YAR 调用前）
-- Front check: whether deadline has already expired (before YAR call)
-- @param deadline_ms number|nil deadline 毫秒数
-- @param request_start number 请求开始时间（platform.now()）
-- @return boolean true 表示 deadline 已过期，应拒绝请求
function _M.check_front(deadline_ms, request_start)
    return _M.check_expired(deadline_ms, request_start)
end

--- 后置检查：deadline 是否已超时（YAR 调用后）
-- Back check: whether deadline exceeded after YAR call
-- @param deadline_ms number|nil deadline 毫秒数
-- @param request_start number 请求开始时间（platform.now()）
-- @return boolean true 表示 deadline 已超时
function _M.check_back(deadline_ms, request_start)
    return _M.check_expired(deadline_ms, request_start)
end

return _M
