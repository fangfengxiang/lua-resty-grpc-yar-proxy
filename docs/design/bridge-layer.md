# 协议桥接决策

## bridge-1: protobuf field number 升序 → 位置参数

**状态：** 已采纳

**决策驱动因素：** gRPC 请求是 protobuf message（字段名 key），YAR 请求是位置参数数组。

**背景：** protobuf message 的字段有 name 和 number。YAR RPC 调用参数是位置数组 `[arg1, arg2, ...]`。

**思考与取舍：**
- 按 field number 升序提取值，构造位置数组
- 缓存排序后的字段名列表（`_sorted_fields_cache`），避免每请求排序
- `nil` 值跳过（未设置的字段不传参）

**业界参考：** grpc-gateway 的 JSON → protobuf 字段映射（但方向相反）。

## bridge-2: YAR retval → protobuf Response 的三路映射

**状态：** 已采纳

**决策驱动因素：** YAR 返回值类型不确定（标量/关联数组/索引数组），需映射到 protobuf message。

**背景：** PHP YAR Server 可返回任意值。gRPC Response 是固定结构的 protobuf message。

**思考与取舍：**
- 标量 → `{ result = retval }`（包装为单字段 message）
- 关联数组 → 直接作为 message table（字段名 key 对齐）
- 索引数组 → 映射到第一个 repeated 字段
- nil → 空消息（google.protobuf.Empty）

**业界参考：** grpc-gateway 的 `body` 映射规则（`body: "*"` 全量映射）。

## bridge-3: gRPC Method 名首字母小写 → YAR method

**状态：** 已采纳

**决策驱动因素：** gRPC Method 名是 PascalCase（如 `Add`），YAR method 名是 camelCase（如 `add`）。

**思考与取舍：**
- `method_to_yar(method)` — 首字母 `lower()`，其余不变
- 简单有效，覆盖 99% 场景
- 不处理 snake_case ↔ camelCase 转换（YAR 约定就是首字母小写）

**业界参考：** PHP Yar 的方法名约定（`$yar_client->add(...)`）。

## bridge-4: Client 缓存按 service 名

**状态：** 已采纳

**决策驱动因素：** persistent Client 跨请求复用，按 service 名缓存。

**背景：** 每个 gRPC Service 对应一个 YAR Server URL，Client 实例可跨请求复用。

**思考与取舍：**
- `_client_cache[service]` — 模块级 table
- `clear_cache()` 清空所有缓存（setup 重新加载时调用）
- Client 创建后设置 persistent + hooks，存入缓存

**业界参考：** lua-resty-yar 的 `get_client(uri, opts)` 弱值表缓存模式。

## bridge-5: hooks 注入集成熔断器和可观测性

**状态：** 已采纳

**决策驱动因素：** 横切关注点（熔断、日志、指标）通过 hooks 注入，不侵入核心桥接逻辑。

**背景：** lua-yar 0.1.0 的 hooks 接口：`on_request(method, params)` / `on_response(method, retval, err_obj)`。

**思考与取舍：**
- `on_request` — 记录调用开始时间 + 触发可观测性 hooks
- `on_response` — 计算延迟 + 熔断器记录 + 触发可观测性 hooks
- 可观测性 hooks 通过 `compose()` 组合，pcall 隔离
- 熔断器仅对 TRANSPORT/TIMEOUT 错误计数

**业界参考：** lua-resty-yar 的 `compose(access_logger, trace_middleware, metrics_recorder)` 模式。
