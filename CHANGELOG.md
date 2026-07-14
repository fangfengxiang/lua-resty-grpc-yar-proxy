# 变更日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 规范，
版本号采用 [语义化版本](https://semver.org/lang/zh-CN/)（SemVer）。

## [Unreleased]

### 新增

- CHANGELOG.md 变更日志
- CONTRIBUTING.md 贡献指南
- CODE_OF_CONDUCT.md 行为准则
- SECURITY.md 安全策略

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
