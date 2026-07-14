# lua-resty-grpc-yar-proxy

基于 [OpenResty](https://openresty.org) 的 gRPC ↔ YAR 协议代理库。

接收 gRPC 客户端的 Unary 请求，自动转换为 YAR 协议转发至后端 PHP YAR Server，再将 YAR 响应转回 gRPC 标准格式返回给客户端。gRPC 客户端无需感知 YAR 协议的存在。

## 特性

- **协议透明转换** — gRPC Unary 请求自动转 YAR 调用，响应自动转回 gRPC 格式（只支持 Unary 一元请求，暂不支持 gRPC stream 流式请求）
- **约定式映射** — 无需逐方法配置，仅需 `services` 表（服务名 → `.pb` 文件 + YAR Server URL）
- **预编译 .pb 加载** — 启动时通过 `pb.load()` 加载二进制描述符，运行时零 `protoc` 依赖
- **流式拒绝** — 对 Server/Client/Bidi streaming 返回 `grpc-status: 12` (UNIMPLEMENTED)
- **标准错误码映射** — YAR 传输/超时/协议错误自动映射为 gRPC 状态码
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
        }
    }

    server {
        listen 443 ssl http2;

        location / {
            content_by_lua_block {
                require("resty.grpc_yar_proxy").serve()
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
├── init.lua       -- 入口模块：setup() 和 serve()
├── codec.lua      -- gRPC 帧编解码（5 字节帧头 + payload）
├── bridge.lua     -- gRPC ↔ YAR 协议转换核心
└── errors.lua     -- gRPC 状态码映射与响应
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
