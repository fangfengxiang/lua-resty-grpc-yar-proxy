-- lib/resty/grpc_yar_proxy/metrics.lua
-- 指标记录 + Prometheus 导出
-- 从 observability.lua 拆出，依赖 trace.lua 的 error_status / CTX_START_TIME
--
-- 函数：
--   metrics_recorder(opts) — hooks 工厂：计数器 + 延迟直方图 + Prometheus export
--
-- 常量：
--   LATENCY_BUCKETS — 延迟直方图桶边界（毫秒），对标 Prometheus histogram 默认 bucket

local ngx = ngx
local pcall = pcall
local type = type
local ipairs = ipairs
local tostring = tostring
local string = string
local table = table

local trace = require("resty.grpc_yar_proxy.trace")
local error_status = trace.error_status
local CTX_START_TIME = trace.CTX_START_TIME

local _M = {}

-- 延迟直方图桶边界（毫秒），对标 Prometheus histogram 默认 bucket
-- Latency histogram bucket boundaries (milliseconds)
local LATENCY_BUCKETS = { 1, 5, 10, 50, 100, 500, 1000, 5000 }

--- 创建指标记录 hooks 工厂
-- 在 on_response 中记录请求计数和延迟直方图到 ngx.shared.DICT
-- 支持通过 export() 导出 Prometheus exposition format
-- @param opts table|nil { dict_name = "grpc_yar_proxy_metrics", prefix = "grpc_yar" }
-- @return table hooks { on_request, on_response, export }
---@param opts? table { dict_name:string, prefix:string }
---@return table hooks { on_request:fun, on_response:fun, export:fun():string }
function _M.metrics_recorder(opts)
    opts = opts or {}
    local dict_name = opts.dict_name or "grpc_yar_proxy_metrics"
    local prefix = opts.prefix or "grpc_yar"

    local function get_dict()
        local ok, dict = pcall(function()
            return ngx.shared[dict_name]
        end)
        if ok and dict then
            return dict
        end
        return nil
    end

    local dict = get_dict()
    if not dict then
        ngx.log(ngx.WARN, "[grpc_yar_proxy metrics] shared dict '" .. dict_name
            .. "' not found, metrics disabled. Add 'lua_shared_dict " .. dict_name
            .. " 1m;' to nginx.conf")
        return {
            on_request = function() end,
            on_response = function() end,
            export = function() return "" end,
        }
    end

    local function counter_key(service, method, kind)
        return prefix .. "_calls_total{service=\"" .. service
            .. "\",method=\"" .. method .. "\",status=\"" .. kind .. "\"}"
    end

    local function bucket_key(service, method, bucket_idx)
        return prefix .. "_duration_bucket{service=\"" .. service
            .. "\",method=\"" .. method .. "\",le=\"" .. LATENCY_BUCKETS[bucket_idx] .. "\"}"
    end

    local function sum_key(service, method)
        return prefix .. "_duration_sum{service=\"" .. service
            .. "\",method=\"" .. method .. "\"}"
    end

    local function count_key(service, method)
        return prefix .. "_duration_count{service=\"" .. service
            .. "\",method=\"" .. method .. "\"}"
    end

    local function record(method, _retval, err_obj)
        local start = ngx.ctx[CTX_START_TIME] or ngx.now()
        local duration_ms = (ngx.now() - start) * 1000
        local status = error_status(err_obj)
        local service = ngx.ctx.grpc_service or "unknown"

        -- 计数器（incr，原子操作）
        local _, cerr = dict:incr(counter_key(service, method, "total"), 1, 0)
        if cerr then
            ngx.log(ngx.WARN, "[grpc_yar_proxy metrics] incr error: " .. tostring(cerr))
        end
        dict:incr(counter_key(service, method, status), 1, 0)

        -- 直方图：找到对应 bucket
        local bucket_idx = #LATENCY_BUCKETS
        for i = 1, #LATENCY_BUCKETS do
            if duration_ms <= LATENCY_BUCKETS[i] then
                bucket_idx = i
                break
            end
        end
        -- 累积直方图：bucket[i] 包含所有 <= LATENCY_BUCKETS[i] 的计数
        for i = 1, bucket_idx do
            dict:incr(bucket_key(service, method, i), 1, 0)
        end
        -- +Inf bucket
        dict:incr(prefix .. "_duration_bucket{service=\"" .. service
            .. "\",method=\"" .. method .. "\",le=\"+Inf\"}", 1, 0)

        -- sum 和 count
        dict:incr(sum_key(service, method), duration_ms, 0)
        dict:incr(count_key(service, method), 1, 0)
    end

    return {
        on_request = function(_method, _params)
            ngx.ctx[CTX_START_TIME] = ngx.now()
        end,
        on_response = function(method, retval, err_obj)
            record(method, retval, err_obj)
        end,
        --- 导出 Prometheus 文本格式
        -- 仅导出以 prefix 开头的 key，过滤共享 dict 中其他模块的数据
        -- @return string Prometheus exposition format
        export = function()
            local keys = dict:get_keys(0)
            local lines = {}

            for _, key in ipairs(keys) do
                if type(key) == "string" and #key > 0
                   and string.sub(key, 1, #prefix) == prefix then
                    local val = dict:get(key) or 0
                    lines[#lines + 1] = key .. " " .. tostring(val)
                end
            end

            return table.concat(lines, "\n") .. "\n"
        end,
    }
end

_M.LATENCY_BUCKETS = LATENCY_BUCKETS

return _M
