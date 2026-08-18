# 变更日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 规范，
版本号采用 [语义化版本](https://semver.org/lang/zh-CN/)（SemVer）。

## [Unreleased]

### 新增

- CHANGELOG.md 变更日志
- CONTRIBUTING.md 贡献指南
- CODE_OF_CONDUCT.md 行为准则
- SECURITY.md 安全策略
- gRPC 状态码扩展：`INVALID_ARGUMENT(3)`、`PERMISSION_DENIED(7)` 预留
- 可观测性增强：`to_json()` 零依赖 JSON 序列化、`flush_logs()` 延迟日志输出、`export()` Prometheus 导出、`get_request_id()` / `ensure_request_id()` 公开 API
- 可观测性 deferred 模式：`access_logger({ defer = true })` 将日志 I/O 移出响应热路径
- `error_status()` 从 Error 对象提取状态字符串
- ADR 文档更新：`obs-5` 延迟日志模式、`obs-6` 公开 API、`error-4` INVALID_ARGUMENT、`error-5` PERMISSION_DENIED

### 变更

- protobuf decode 失败和 gRPC path 格式错误从 `INTERNAL(13)` 改为 `INVALID_ARGUMENT(3)`
- `observability.lua` 访问日志从文本格式改为结构化 JSON 格式
- `observability.lua` 请求 ID 格式从 15 字符改为 8 字符十六进制
- `observability.lua` 指标 key 格式从 `req:svc:method:status` 改为 Prometheus 标签格式 `grpc_yar_calls_total{service="...",method="...",status="..."}`
- `init.lua` 请求 ID 生成从内联逻辑改为委托 `observability.ensure_request_id()`
- `init.lua log_phase()` 增加 `observability.flush_logs()` 调用
- `errors.lua send_ok/send_error` 增加 trailer 处理限制说明
- `t/observability.t` 重写以匹配新 JSON API（10 tests）
- `t/errors.t` 常量测试增加 `INVALID_ARGUMENT` 和 `PERMISSION_DENIED`
- `t/error-scenarios.t` 和 `t/integration.t` 错误码期望值从 13 改为 3

## [0.2.0] - 2026-08-17

### 新增

- gRPC deadline 解析与前后检查（`deadline.lua` 新模块）
- 熔断器：3 态状态机（CLOSED/OPEN/HALF_OPEN），跨 worker 状态（`circuit_breaker.lua` 新模块）
- 可观测性：请求 ID、结构化访问日志、指标记录（`observability.lua` 新模块）
- 可组合 hooks 工厂模式（`access_logger`/`trace_middleware`/`metrics_recorder`/`compose`）
- 请求 ID 多熵源生成（timestamp + worker pid + counter）
- 延迟直方图（ngx.shared.DICT，8 个桶边界）
- Body spill 预防（WARN 日志 + nginx 配置指导）
- `log_phase()` 异步日志阶段（request_id + service + method + status + latency）
- ADR 设计文档（24 个决策，7 个模块文件）
- BDD 测试：`t/deadline.t`（10 tests）、`t/circuit_breaker.t`（8 tests）、`t/observability.t`（8 tests）

### 变更

- 版本号升级至 0.2.0
- `init.lua` 集成 deadline 检查、熔断器检查、请求 ID 生成
- `bridge.lua` hooks 注入集成熔断器记录和可观测性 hooks
- `log_phase()` 输出增加 request_id 字段
- README 增加 nginx 配置示例（lua_shared_dict、client_body_buffer_size、log_by_lua_block）

## [0.1.0] - 2026-07-10

### 新增

- gRPC Unary 请求 → YAR 协议自动转换
- 预编译 `.pb` 描述符加载（`pb.load()`），运行时零 `protoc` 依赖
- 约定式映射：`{Service}_{Method}Request/Response` 消息名 + field number → 位置参数
- gRPC 帧编解码（5 字节帧头 + protobuf payload）
- 流式请求拒绝（Server/Client/Bidi streaming → `grpc-status: 12`）
- YAR 错误 → gRPC 状态码自动映射（超时/协议/传输错误）
- OpenResty cosocket 注入（`Yar.Client.set_socket(ngx.socket)`）
- 模块级缓存（类型名、字段排序、索引字段映射）
- `setup(opts)` + `serve()` 双 API 设计
- test-nginx 测试套件
- Apache License 2.0

[Unreleased]: https://github.com/fangfengxiang/lua-resty-grpc-yar-proxy/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/fangfengxiang/lua-resty-grpc-yar-proxy/releases/tag/v0.1.0
