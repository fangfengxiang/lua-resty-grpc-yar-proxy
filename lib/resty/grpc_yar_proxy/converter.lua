-- lib/resty/grpc_yar_proxy/converter.lua
-- 纯协议转换层：gRPC path/method/protobuf ↔ YAR method/params/retval
-- 零 ngx.* 依赖，可独立单元测试
--
-- 从 bridge.lua 提取的纯函数：
--   parse_grpc_path(path)           — 解析 /{Service}/{Method}
--   method_to_yar(method)           — gRPC Method → YAR method（首字母小写）
--   extract_params(decoded, type)   — protobuf message → YAR 位置参数数组
--   map_response(retval, type)      — YAR retval → protobuf Response message table
--   get_type_names(service, method) — 获取 Request/Response 类型名（带缓存）
--   clear_cache()                   — 清空模块级缓存

local pb = require("pb")

local _M = {}

-- 模块级缓存：pb.fields 排序后的字段名列表（按类型名索引）
local _sorted_fields_cache = {}
-- 模块级缓存：Response 索引数组映射所需的 field 1 / repeated 字段名（按类型名索引）
local _idx_fields_cache = {}
-- 模块级缓存：类型名字符串拼接结果按 service/method 缓存
local _type_cache = {}

--- 清空所有模块级缓存（供 init.setup 重新加载时调用）
function _M.clear_cache()
    _sorted_fields_cache = {}
    _idx_fields_cache = {}
    _type_cache = {}
end

--- 从 `/{Service}/{Method}` 解析出 Service 和 Method
-- @param path string gRPC path（ngx.var.uri）
-- @return service string|nil
-- @return method string|nil
-- @return err string|nil 错误信息
function _M.parse_grpc_path(path)
    if not path or path == "" then
        return nil, nil, "invalid gRPC path: empty"
    end
    -- 去除前导 / 并匹配 {Service}/{Method} 格式
    local service, method = path:match("^/+([^/]+)/([^/]+)$")
    if not service or not method or service == "" or method == "" then
        return nil, nil, "invalid gRPC path: " .. (path or "nil")
    end
    return service, method
end

--- 将 gRPC Method 名首字母小写作为 YAR method 名
-- @param method string gRPC Method 名（如 "Add"）
-- @return string YAR method 名（如 "add"）
function _M.method_to_yar(method)
    if not method or #method == 0 then
        return method
    end
    local first = method:sub(1, 1):lower()
    local rest  = method:sub(2)
    return first .. rest
end

--- 按 field number 升序提取值构造位置参数数组
-- @param decoded table pb.decode 返回的 table（field name 为 key）
-- @param request_type string protobuf message 类型名
-- @return params table 位置参数数组 { [1]=v1, [2]=v2, ... }
function _M.extract_params(decoded, request_type)
    decoded = decoded or {}

    -- 从缓存获取按 field number 升序排列的字段名列表
    local sorted_names = _sorted_fields_cache[request_type]
    if not sorted_names then
        local fields = {}
        for name, number in pb.fields(request_type) do
            table.insert(fields, { name = name, number = number })
        end
        table.sort(fields, function(a, b) return a.number < b.number end)
        sorted_names = {}
        for i, f in ipairs(fields) do
            sorted_names[i] = f.name
        end
        _sorted_fields_cache[request_type] = sorted_names
    end

    -- 按缓存的字段顺序提取值
    local params = {}
    for _, name in ipairs(sorted_names) do
        local val = decoded[name]
        if val ~= nil then
            table.insert(params, val)
        end
    end
    return params
end

--- 将 YAR retval 映射为 protobuf Response message table
-- @param retval any YAR 返回值
-- @param response_type string protobuf message 类型名
-- @return table 可直接 pb.encode 的 message table
function _M.map_response(retval, response_type)
    -- nil 返回值 → 空消息（google.protobuf.Empty 或无字段消息）
    if retval == nil then
        return {}
    end

    -- 标量返回值 → 包装为 { result = retval }
    if type(retval) ~= "table" then
        return { result = retval }
    end

    -- 索引数组（retval[1] ~= nil）→ 优先用 field 1（仅当 repeated），其次用第一个 repeated 字段
    if retval[1] ~= nil then
        -- 从缓存获取 field 1 名和首个 repeated 字段名
        local cached = _idx_fields_cache[response_type]
        if not cached then
            local f1_name
            local f1_repeated
            local first_rep
            for name, number, _, _, label in pb.fields(response_type) do
                if number == 1 then
                    f1_name = name
                    f1_repeated = (label == "repeated")
                end
                if not first_rep and label == "repeated" then
                    first_rep = name
                end
            end
            -- field 1 仅当为 repeated 时才优先使用，否则用首个 repeated 字段
            cached = { key = (f1_repeated and f1_name) or first_rep }
            _idx_fields_cache[response_type] = cached
        end
        local key = cached.key
        if key then
            return { [key] = retval }
        end
        -- 兜底：直接返回
        return retval
    end

    -- 关联数组 → 直接作为 message table
    return retval
end

--- 获取 Request/Response 类型名（带缓存，避免每请求字符串拼接）
-- @param service string gRPC Service 名
-- @param method string gRPC Method 名
-- @return table { request = string, response = string }
function _M.get_type_names(service, method)
    local cache_key = service .. "/" .. method
    local types = _type_cache[cache_key]
    if not types then
        types = {
            request  = service .. "_" .. method .. "Request",
            response = service .. "_" .. method .. "Response",
        }
        _type_cache[cache_key] = types
    end
    return types
end

return _M
