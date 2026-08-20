-- lib/resty/grpc_yar_proxy/reverse_bridge.lua
-- 反向桥接占位：YAR → gRPC 方向
-- 接受 YAR 协议请求，转换为 gRPC 调用，返回 YAR 协议响应
--
-- 依赖注入设计（对标 lua-yar set_socket / set_http_provider 模式）：
--   set_grpc_transport(fn)  — 注入 gRPC 传输层可调用对象
--   默认实现：ngx.location.capture + grpc_pass（nginx 内部代理到 gRPC upstream）
--
-- TODO: 实现完整管线
--   1. YAR 请求解码（packager.unpack + header 解析）
--   2. 方法路由：YAR method → gRPC Service/Method
--   3. 参数转换：YAR 位置参数 → protobuf message table
--   4. gRPC 调用（通过注入的 transport）
--   5. 响应转换：gRPC response → YAR retval
--   6. YAR 响应编码（packager.pack + header 构造）

local _M = {}

-- 注入的 gRPC 传输层可调用对象
-- 签名：transport(service, method, payload) -> payload|nil, status, err
-- 默认 nil，需由 init.setup 注入
local _grpc_transport = nil

--- 注入 gRPC 传输层可调用对象
-- 对标 lua-yar Yar.Client.set_socket(ngx.socket) 注入模式
-- 库不决定传输层实现，由宿主注入
-- @param fn function grpc_transport(service, method, payload) -> payload|nil, status, err
function _M.set_grpc_transport(fn)
    _grpc_transport = fn
end

--- 处理 YAR 请求并返回 gRPC 转换后的响应
-- TODO: 完整实现
-- @param yar_request string YAR 协议原始请求体
-- @return yar_response string|nil YAR 协议响应体
-- @return err string|nil 错误信息
function _M.handle(yar_request)
    if not _grpc_transport then
        return nil, "grpc transport not injected, call set_grpc_transport() first"
    end

    -- TODO: 实现完整管线
    error("reverse_bridge.handle: not implemented yet", 2)
end

return _M
