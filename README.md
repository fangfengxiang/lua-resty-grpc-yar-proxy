# lua-resty-grpc-yar-proxy

gRPC to YAR protocol proxy for [OpenResty](https://openresty.org), bridging gRPC clients to PHP YAR servers.

## Features

- **Protocol proxy** — receives gRPC Unary requests, converts to YAR protocol, forwards to backend YAR Server, converts response back to gRPC
- **Convention-based mapping** — no per-method config needed, only `services` (service name → proto file + YAR Server URL)
- **Pre-compiled .pb loading** — loads protobuf descriptors via `pb.load()` at startup, no `protoc` dependency at runtime
- **Streaming rejection** — returns `grpc-status: 12` (UNIMPLEMENTED) for Server/Client/Bidi streaming modes
- **Standard gRPC error mapping** — YAR transport/timeout/protocol errors mapped to gRPC status codes
- **Minimal dependencies** — `lua-yar` + `lua-protobuf` + OpenResty

## Installation

### Step 1: Install lua-yar (LuaRocks)

```bash
luarocks install lua-yar
```

### Step 2: Install lua-protobuf (LuaRocks)

```bash
luarocks install lua-protobuf
```

### Step 3: Install lua-resty-grpc-yar-proxy (OPM)

```bash
opm get fangfengxiang/lua-resty-grpc-yar-proxy
```

## Quick Start

### 1. Generate .pb files

Use the [yar2proto](docs/protocol-generator.md) tool to generate `.proto` and `.pb` files from your PHP YAR Server code.

#### Tool overview

`yar2proto` is an **independent CLI tool** (not part of this OPM package). It analyzes PHP YAR Server code and generates gRPC `.proto` / `.pb` descriptor files that this proxy loads at startup.

```
┌─────────────────────────────────────────────────────────────────┐
│                    工具链全景                                      │
│                                                                 │
│  PHP YAR Server          Protocol Generator          OPM Package│
│  ┌───────────┐           ┌──────────────┐           ┌────────┐│
│  │ Calculator │           │  yar2proto   │           │  proxy ││
│  │ .php       │──────────▶│  (独立工具)   │──────────▶│  (OPM) ││
│  │            │  PHP 反射  │  生成 .proto  │  .pb 文件  │  加载   ││
│  │ @yar-rpc   │  或静态    │  编译 .pb    │           │  .pb   ││
│  └───────────┘  分析      └──────────────┘           └────────┘│
│       ▲                                                    │    │
│       │              运行时 gRPC 调用                       │    │
│       │                                                    ▼    │
│       │           gRPC Client ──▶ OpenResty ──▶ YAR Server    │
│       │                              (proxy)                   │
│       └──────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

#### Two implementation forms

| Form | Analysis | .pb Generation | Distribution | Status |
|------|-----------|----------------|--------------|--------|
| **A: Pure PHP CLI** | nikic/PHP-Parser (AST) | protoc subprocess | `composer global require` | Reference impl (priority) |
| **B: PHP Extension** | Zend engine AST (C) | protobuf-c inline (optional) | `pecl install` + composer | Future |

Both forms share the same CLI interface, output format, and naming conventions. Form B auto-falls-back to Form A when the extension is not loaded.

#### Quick start (Form A)

```bash
# Install
composer global require yar/proto-generator

# Generate from PHP source (Mode 1: annotation-based)
yar2proto generate src/Calculator.php \
    --output=proto/calc.pb --keep-proto

# Generate from running YAR Server (Mode 2: introspection)
yar2proto generate --server=http://127.0.0.1:8888/api \
    --service=Calculator --output=proto/calc.pb
```

#### Example: PHP YAR Server → .proto

```php
// src/Calculator.php
class Calculator {
    /** @yar-rpc @param int $a @param int $b @return int */
    public function add($a, $b) { return $a + $b; }
}
```

Generates:

```protobuf
message Calculator_AddRequest { int32 a = 1; int32 b = 2; }
message Calculator_AddResponse { int32 result = 1; }
service Calculator { rpc Add(Calculator_AddRequest) returns (Calculator_AddResponse); }
```

> See [docs/protocol-generator.md](docs/protocol-generator.md) for full implementation code, type mapping rules, annotation conventions, and architecture diagrams.

### 2. Configure nginx

```nginx
http {
    lua_package_path ";;";

    init_by_lua_block {
        require("resty.grpc_yar_proxy").setup {
            services = {
                Calculator = {
                    proto = "/path/to/proto/calc.pb",
                    url   = "http://127.0.0.1:8888/api",
                    -- options = { timeout = 5000 },  -- per-service override
                },
                -- UserService = {
                --     proto   = "/path/to/proto/user.pb",
                --     url     = "http://127.0.0.1:8889/api",
                --     options = { timeout = 5000 },
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

### 3. Call from gRPC client

gRPC clients call `/{Service}/{Method}` — e.g. `/Calculator/Add` — and the proxy transparently converts to a YAR `add` call.

## API

### `require("resty.grpc_yar_proxy").setup(opts)`

Call once in `init_by_lua_block`. Loads .pb files, stores service configs, injects cosocket.

**Parameters:**

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `services` | `table` | Yes | Service name → `{ proto=, url=, options= }` |
| `yar_options` | `table` | No | Default YAR client options (timeout, connect_timeout, etc.) |

### `require("resty.grpc_yar_proxy").serve()`

Call in `content_by_lua_block`. Handles a single gRPC request lifecycle.

## Naming Convention

The `yar2proto` tool and this proxy share a strict naming contract:

| Element | Convention | Example |
|---------|-----------|---------|
| gRPC path | `/{Service}/{Method}` | `/Calculator/Add` |
| Request message | `{Service}_{Method}Request` | `Calculator_AddRequest` |
| Response message | `{Service}_{Method}Response` | `Calculator_AddResponse` |
| YAR method | Method name, first letter lowercase | `add` |
| Request params | Field number → positional param | field 1 → params[1] |
| Response (scalar) | Wrapped as `{ result = retval }` | `{ result = 42 }` |
| Response (assoc) | Field name → PHP key alignment | `{ name = "alice" }` |
| Response (indexed) | First repeated field name as key | `{ items = {...} }` |

## gRPC Error Codes

| gRPC Status | Code | Trigger |
|-------------|------|---------|
| OK | 0 | Success |
| NOT_FOUND | 5 | Service not in `services` |
| UNIMPLEMENTED | 12 | Streaming mode or compression |
| INTERNAL | 13 | Protobuf error, YAR protocol error |
| UNAVAILABLE | 14 | YAR transport error |
| DEADLINE_EXCEEDED | 4 | YAR timeout |

## Module Structure

```
lib/resty/grpc_yar_proxy/
  init.lua       -- Entry module: setup() and serve()
  codec.lua      -- gRPC frame encode/decode (5-byte header + payload)
  bridge.lua     -- gRPC ↔ YAR protocol conversion core
  errors.lua     -- gRPC status code mapping and response
```

## Development

### Prerequisites

- OpenResty >= 1.19.3.1
- lua-yar (LuaRocks)
- lua-protobuf (LuaRocks)
- Perl (for test-nginx)
- luacheck (for linting)

### Run Tests

```bash
make test
```

### Run Linter

```bash
make lint
```

## License

Apache License 2.0

## Author

fangfengxiang
