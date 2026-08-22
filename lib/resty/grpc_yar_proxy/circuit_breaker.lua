-- lib/resty/grpc_yar_proxy/circuit_breaker.lua
-- 熔断器：3 态状态机，隔离 YAR 后端故障
-- Circuit breaker: 3-state machine for YAR backend failure isolation
--
-- 状态转换：CLOSED → OPEN → HALF_OPEN → CLOSED
--   CLOSED:     正常放行请求，记录连续失败数
--   OPEN:       拒绝所有请求，等待冷却时间后转 HALF_OPEN
--   HALF_OPEN:  放行有限探测请求，成功 → CLOSED，失败 → OPEN
--
-- 跨 worker 状态：使用 platform.shared_dict() 存储状态（生产环境）
-- 无 shared dict 时回退到模块级 table（测试环境/降级模式）
--
-- hooks 驱动：on_response 回调记录成功/失败，不侵入 bridge.lua
-- 仅传输层错误（TRANSPORT/TIMEOUT）触发失败计数，协议错误是客户端 bug 不计入

local platform = require("resty.grpc_yar_proxy.platform")
local Yar = require("yar")

local _M = {}
_M.VERSION = "0.1.0"

-- 熔断器状态常量
-- Circuit breaker state constants
_M.CLOSED     = "closed"
_M.OPEN       = "open"
_M.HALF_OPEN  = "half_open"

-- 默认配置
-- Default configuration
local DEFAULT_FAILURE_THRESHOLD = 5
local DEFAULT_COOLDOWN_MS       = 5000
local DEFAULT_HALF_OPEN_MAX     = 1

-- 模块级配置（init 后填充）
-- Module-level configuration (populated after init)
_M._failure_threshold = DEFAULT_FAILURE_THRESHOLD
_M._cooldown_ms       = DEFAULT_COOLDOWN_MS
_M._half_open_max     = DEFAULT_HALF_OPEN_MAX

-- platform.shared_dict() 名称
-- platform.shared_dict() name for cross-worker state
local _dict_name = "grpc_yar_proxy_cb"

-- 模块级 fallback table（无 shared dict 时使用）
-- Module-level fallback table (used when no shared dict available)
local _fallback_state = {}

--- 初始化熔断器配置
-- Initialize circuit breaker configuration
-- @param opts table|nil { failure_threshold=, cooldown_ms=, half_open_max=, dict_name= }
-- @return _M self（链式调用）
function _M.init(opts)
    opts = opts or {}
    _M._failure_threshold = opts.failure_threshold or DEFAULT_FAILURE_THRESHOLD
    _M._cooldown_ms       = opts.cooldown_ms or DEFAULT_COOLDOWN_MS
    _M._half_open_max     = opts.half_open_max or DEFAULT_HALF_OPEN_MAX
    if opts.dict_name then
        _dict_name = opts.dict_name
    end
    _fallback_state = {}
    return _M
end

-- 获取 shared dict（惰性，测试环境可能不存在）
-- Get shared dict (lazy, may not exist in test env)
local function get_dict()
    local ok, dict = pcall(function()
        return platform.shared_dict(_dict_name)
    end)
    if ok and dict then
        return dict
    end
    return nil
end

-- 生成 dict key（URL → 状态）
local function state_key(url)
    return "cb:state:" .. url
end

-- 生成 dict key（URL → 失败计数）
local function count_key(url)
    return "cb:count:" .. url
end

-- 生成 dict key（URL → 最后失败时间戳 ms）
local function last_fail_key(url)
    return "cb:lastfail:" .. url
end

-- 生成 dict key（URL → HALF_OPEN 探测计数）
local function probe_key(url)
    return "cb:probe:" .. url
end

-- 从 fallback table 获取值
local function fallback_get(key)
    return _fallback_state[key]
end

-- 从 fallback table 设置值
local function fallback_set(key, val)
    _fallback_state[key] = val
end

-- 统一的 get 操作（优先 shared dict，回退 fallback）
local function store_get(url, key_fn)
    local dict = get_dict()
    local key = key_fn(url)
    if dict then
        return dict:get(key)
    end
    return fallback_get(key)
end

-- 统一的 set 操作
local function store_set(url, key_fn, val)
    local dict = get_dict()
    local key = key_fn(url)
    if dict then
        dict:set(key, val)
    else
        fallback_set(key, val)
    end
end

-- 统一的 incr 操作
local function store_incr(url, key_fn, by, init)
    local dict = get_dict()
    local key = key_fn(url)
    if dict then
        return dict:incr(key, by, init)
    end
    local cur = fallback_get(key) or init
    fallback_set(key, cur + by)
    return cur + by
end

--- 检查请求是否允许通过
-- Check if a request to the given URL should be allowed
-- @param url string YAR 后端 URL
-- @return boolean true 表示允许通过
function _M.allow(url)
    if not url then
        return true
    end

    local state = store_get(url, state_key) or _M.CLOSED

    if state == _M.CLOSED then
        return true
    elseif state == _M.OPEN then
        -- 检查冷却时间是否已过
        local last_fail = store_get(url, last_fail_key) or 0
        local now = platform.now() * 1000
        if now - last_fail >= _M._cooldown_ms then
            -- 转入 HALF_OPEN，放行探测请求
            store_set(url, state_key, _M.HALF_OPEN)
            return true
        end
        return false
    elseif state == _M.HALF_OPEN then
        -- HALF_OPEN 放行有限探测请求，超过 half_open_max 则拒绝
        -- HALF_OPEN allows limited probe requests up to half_open_max
        local probe_count = store_incr(url, probe_key, 1, 0)
        if probe_count <= _M._half_open_max then
            return true
        end
        return false
    end

    return true
end

--- 记录成功调用
-- Record a successful call to the given URL
-- @param url string YAR 后端 URL
function _M.record_success(url)
    if not url then
        return
    end

    -- 重置失败计数和探测计数，转入 CLOSED
    store_set(url, count_key, 0)
    store_set(url, probe_key, 0)
    store_set(url, state_key, _M.CLOSED)
end

--- 记录失败调用
-- Record a failed call to the given URL
-- @param url string YAR 后端 URL
-- @param error_code string|nil YAR Error code（用于判断是否计入熔断）
function _M.record_failure(url, error_code)
    if not url then
        return
    end

    -- 仅传输层错误和超时触发熔断，协议错误是客户端 bug 不计入
    -- Only transport/timeout errors trigger circuit breaker
    if error_code and error_code ~= Yar.Error.TRANSPORT and error_code ~= Yar.Error.TIMEOUT then
        return
    end

    local state = store_get(url, state_key) or _M.CLOSED

    if state == _M.HALF_OPEN then
        -- 探测失败，回到 OPEN，清空探测计数
        store_set(url, state_key, _M.OPEN)
        store_set(url, probe_key, 0)
        store_set(url, last_fail_key, platform.now() * 1000)
        return
    end

    if state == _M.CLOSED then
        local count = store_incr(url, count_key, 1, 0)
        if count >= _M._failure_threshold then
            store_set(url, state_key, _M.OPEN)
            store_set(url, last_fail_key, platform.now() * 1000)
        end
    end
end

--- 获取熔断器状态（调试/监控用）
-- Get circuit breaker state for a URL (for debugging/monitoring)
-- @param url string YAR 后端 URL
-- @return string 状态（"closed"/"open"/"half_open"）
function _M.get_state(url)
    if not url then
        return _M.CLOSED
    end
    return store_get(url, state_key) or _M.CLOSED
end

--- 重置指定 URL 的熔断器状态（管理/测试用）
-- Reset circuit breaker state for a URL (for admin/testing)
-- @param url string YAR 后端 URL
function _M.reset(url)
    if not url then
        return
    end
    store_set(url, state_key, _M.CLOSED)
    store_set(url, count_key, 0)
    store_set(url, probe_key, 0)
    store_set(url, last_fail_key, nil)
end

--- 重置所有熔断器状态（测试用）
-- Reset all circuit breaker state (for testing)
function _M.reset_all()
    local dict = get_dict()
    if dict then
        dict:flush_all()
    end
    _fallback_state = {}
end

return _M
