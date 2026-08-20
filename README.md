# lua-resty-grpc-yar-proxy

基于 [OpenResty](https://openresty.org) 的 gRPC ↔ YAR 协议代理库。

接收 gRPC 客户端的 Unary 请求，自动转换为 YAR 协议转发至后端 PHP YAR Server，再将 YAR 响应转回 gRPC 标准格式返回给客户端。gRPC 客户端无需感知 YAR 协议的存在。

## 特性

- **协议透明转换** — gRPC Unary 请求自动转 YAR 调用，响应自动转回 gRPC 格式（只支持 Unary 一元请求，暂不支持 gRPC stream 流式请求）
- **约定式映射** — 无需逐方法配置，仅需 `services` 表（服务名 → `.pb` 文件 + YAR Server URL）
- **预编译 .pb 加载** — 启动时通过 `pb.load()` 加载二进制描述符，运行时零 `protoc` 依赖
- **流式拒绝** — 对 Server/Client/Bidi streaming 返回 `grpc-status: 12` (UNIMPLEMENTED)
- **标准错误码映射** — YAR 传输/超时/协议错误自动映射为 gRPC 状态码；客户端参数错误返回 `INVALID_ARGUMENT(3)`
- **Deadline 传播** — 解析 `grpc-timeout` header，前后检查 deadline 是否过期
- **熔断器** — 3 态状态机（CLOSED/OPEN/HALF_OPEN），跨 worker 状态，hooks 驱动
- **可观测性** — 请求 ID、结构化 JSON 访问日志、Prometheus 指标导出、deferred 日志模式，可组合 hooks
- **非阻塞 I/O** — 出向 YAR 调用走 OpenResty cosocket，不阻塞 worker
- **最小依赖** — `lua-yar` + `lua-protobuf` + OpenResty

## 依赖

- [OpenResty](https://openresty.org) >= 1.19.3.1
- [lua-yar](https://github.com/fangfengxiang/lua-yar)（YAR 协议库）
- [lua-protobuf](https://github.com/starwing/lua-protobuf)（protobuf 编解码）

## 安装

```bash
# 1. 安装 lua-yar
luarocks install lua-yar

# 2. 安装 lua-protobuf
luarocks install lua-protobuf

# 3. 安装本库
opm get fangfengxiang/lua-resty-grpc-yar-proxy
```

## 快速开始

```nginx
http {
    lua_package_path ";;";

    # 熔断器和指标共享内存（可选，无则降级为模块级 table）
    lua_shared_dict grpc_yar_proxy_cb 1m;
    lua_shared_dict grpc_yar_proxy_metrics 1m;

    # 防止请求体 spill 到磁盘
    client_body_buffer_size 2m;

    init_by_lua_block {
        local proxy = require("resty.grpc_yar_proxy")

        proxy.setup {
            services = {
                Calculator = {
                    proto = "/path/to/proto/calc.pb",   -- 预编译 .pb 描述符
                    url   = "http://127.0.0.1:8888/api",  -- YAR Server 地址
                },
                -- UserService = {
                --     proto   = "/path/to/proto/user.pb",
                --     url     = "http://127.0.0.1:8889/api",
                --     options = { timeout = 5000 },      -- 可选：per-service 覆盖
                -- },
            },
            yar_options = {
                timeout         = 3000,
                connect_timeout = 1000,
            },
            -- 熔断器配置（可选）
            circuit_breaker = {
                failure_threshold = 5,
                cooldown_ms       = 5000,
            },
        }
    }

    server {
        listen 443 ssl http2;

        location / {
            content_by_lua_block {
                require("resty.grpc_yar_proxy").serve()
            }

            # 异步日志/指标阶段（可选，推荐启用）
            log_by_lua_block {
                require("resty.grpc_yar_proxy").log_phase()
            }
        }
    }
}
```

gRPC 客户端调用 `/{Service}/{Method}`（如 `/Calculator/Add`），代理自动转换为 YAR `add` 调用并返回 gRPC 响应。

> 完整 API、命名约定与 gRPC 状态码详见 [docs/api.md](docs/api.md)。

## 模块结构

```
lib/resty/grpc_yar_proxy/
├── init.lua             -- 入口模块：setup() 和 serve() 和 log_phase()
├── codec.lua            -- gRPC 帧编解码（5 字节帧头 + payload）
├── converter.lua        -- 纯协议转换层（零 ngx.* 依赖，可独立测试）
├── bridge.lua           -- 正向桥接：gRPC → YAR（调用 converter + 可观测性 hooks）
├── reverse_bridge.lua   -- 反向桥接：YAR → gRPC（占位，依赖注入传输层）
├── errors.lua           -- gRPC 状态码映射与响应
├── deadline.lua         -- gRPC deadline 解析与前后检查
├── circuit_breaker.lua  -- 熔断器（3 态状态机，跨 worker）
├── trace.lua            -- 请求 ID 管理 + hooks 组合（compose）+ 错误状态
├── log.lua              -- 结构化 JSON 访问日志 + 延迟日志输出
└── metrics.lua          -- 指标记录 + Prometheus 导出
```

## 可观测性 API

可观测性拆分为 3 个模块：`trace.lua`（基础模块）、`log.lua`、`metrics.lua`。

### trace.lua

| 函数 / 工厂 | 说明 |
|---|---|
| `get_request_id()` | 获取当前请求 ID（从 `ngx.ctx` 读取或生成） |
| `ensure_request_id(header_name?)` | 从 header 提取或生成请求 ID，存入 `ngx.ctx` |
| `trace_middleware(opts?)` | hooks 工厂：生成/提取请求 ID |
| `compose(...)` | 组合多个 hooks，每个 hook 独立 pcall 隔离 |
| `error_status(err_obj?)` | 从 Error 对象提取错误状态字符串 |

### log.lua

| 函数 / 工厂 | 说明 |
|---|---|
| `access_logger(opts?)` | hooks 工厂：结构化 JSON 访问日志（支持 `defer=true` 延迟模式） |
| `flush_logs(opts?)` | 在 `log_by_lua` 阶段输出延迟的访问日志 |

### metrics.lua

| 函数 / 工厂 | 说明 |
|---|---|
| `metrics_recorder(opts?)` | hooks 工厂：ngx.shared.DICT 计数器 + 延迟直方图 + `export()` |

**Deferred 日志模式** — 将日志 I/O 移出响应热路径：

```nginx
init_by_lua_block {
    local trace = require("resty.grpc_yar_proxy.trace")
    local log = require("resty.grpc_yar_proxy.log")
    local metrics = require("resty.grpc_yar_proxy.metrics")
    -- 使用 defer=true，on_response 仅存储 entry 到 ngx.ctx
    local hooks = trace.compose(
        trace.trace_middleware(),
        log.access_logger({ defer = true }),
        metrics.metrics_recorder()
    )
    -- hooks 注入到 bridge.lua 的 YAR Client 中...
}

# log_by_lua 阶段调用 flush_logs() 输出延迟日志
log_by_lua_block {
    require("resty.grpc_yar_proxy.log").flush_logs()
}
```

**Prometheus 指标导出** — 通过 `export()` 函数获取 Prometheus exposition format：

```nginx
location /metrics {
    content_by_lua_block {
        local metrics = require("resty.grpc_yar_proxy.metrics")
        local hooks = metrics.metrics_recorder()
        ngx.header["content-type"] = "text/plain"
        ngx.say(hooks.export())
    }
}
```

## 开发

### 环境要求

- OpenResty >= 1.19.3.1
- Perl（[test-nginx](https://github.com/openresty/test-nginx) 测试框架）
- [luacheck](https://github.com/mpeterv/luacheck)（代码检查）

### 运行测试

```bash
make test
```

### 代码检查

```bash
make lint
```

## License

[Apache License 2.0](LICENSE)
