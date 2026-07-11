# YAR-to-gRPC Protocol Generator

## 定位

协议生成工具是一个**独立的命令行工具**，不属于 `lua-resty-grpc-yar-proxy` OPM 包的一部分。它的职责是：分析 PHP YAR Server 的服务代码，自动生成对应的 gRPC `.proto` 协议文件和编译后的 `.pb` 二进制描述符。

工具采用**多语言架构**：规范语言无关，各生态用自己最自然的方式实现。PHP 为参考实现（优先），后续可由社区贡献 Python、Go 等版本。PHP 实现可从纯 PHP CLI 工具（Composer 包）渐进到 PHP 扩展（PECL），在 CLI 模式下安装即用。

```
┌─────────────────────────────────────────────────────────────────┐
│                    工具链全景                                      │
│                                                                 │
│  PHP YAR Server          Protocol Generator          OPM Package│
│  ┌───────────┐           ┌──────────────┐           ┌────────┐│
│  │ Calculator│           │  yar2proto    │           │  proxy ││
│  │ .php      │──────────▶│  (独立工具)   │──────────▶│  (OPM) ││
│  │           │           │               │  .pb      │        ││
│  │ function  │  PHP 反射  │  生成 .proto  │  文件      │  加载   ││
│  │  add($a,  │  或静态    │  编译 .pb     │           │  .pb   ││
│  │  $b)      │  分析      │               │           │        ││
│  └───────────┘           └──────────────┘           └────────┘│
│       ▲                                                    │    │
│       │              运行时 gRPC 调用                       │    │
│       │                                                    ▼    │
│       │           gRPC Client ──▶ OpenResty ──▶ YAR Server    │
│       │                              (proxy)                   │
│       └──────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

**工具不在 OPM 包代码中**，但两者通过约定协议（.pb 文件中的 message/service 命名规则）紧密配合。工具保证生成的 .proto 符合 OPM 包运行时的约定映射规则，使得 proxy 无需 per-method 配置即可工作。

## 多语言架构

### 设计哲学

协议生成工具的**规范（specification）是语言无关的**——输入格式、输出格式、命名约定、类型映射规则对所有实现统一。但**实现（implementation）是各语言一套**，每个语言生态用自己最自然的方式实现。

```
┌──────────────────────────────────────────────────────────────────┐
│              多语言实现架构                                        │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              工具规范 (Language-Agnostic)                │    │
│  │                                                         │    │
│  │  - 输入: PHP 源码 / YAR Server URL                      │    │
│  │  - 输出: .proto 文本 + .pb 二进制描述符                  │    │
│  │  - 命名约定: {Service}_{Method}Request/Response          │    │
│  │  - 类型映射: PHP 类型 → Protobuf 类型                    │    │
│  │  - 注解约定: @yar-rpc / @yar-skip                       │    │
│  │  - 两种模式: 注解模式 / 内省模式                          │    │
│  └──────────────────────┬──────────────────────────────────┘    │
│                         │                                       │
│         ┌───────────────┼───────────────┐                      │
│         │               │               │                      │
│         ▼               ▼               ▼                      │
│  ┌──────────────┐ ┌──────────┐ ┌──────────────┐               │
│  │ PHP 实现      │ │ Python  │ │ Go 实现       │  ...          │
│  │ (参考实现)    │ │ 实现     │ │               │               │
│  │              │ │          │ │               │               │
│  │ PHP-Parser   │ │ php-     │ │ go-php        │               │
│  │ 或 Reflection│ │ parser  │ │ 解析器        │               │
│  │ + protoc     │ │ +protoc │ │ + protoc      │               │
│  │              │ │          │ │               │               │
│  │ 分发:        │ │ 分发:    │ │ 分发:         │               │
│  │ PECL 扩展    │ │ pip      │ │ go install    │               │
│  │ + Composer   │ │          │ │               │               │
│  └──────────────┘ └──────────┘ └──────────────┘               │
│                                                                  │
│  各实现共享同一规范，输出格式完全一致                              │
│  OPM 包不关心 .pb 是哪个工具生成的                                │
└──────────────────────────────────────────────────────────────────┘
```

### 各语言实现路线

| 语言 | 代码分析方式 | .pb 生成方式 | 分发方式 | 状态 |
|------|-------------|-------------|---------|------|
| **PHP** | PHP-Parser (静态) 或 Reflection (运行时) | protoc 子进程 或 编程构造 | PECL 扩展 + Composer | **参考实现 (优先)** |
| **Python** | php-parser 库 (静态) | protoc 子进程 或 descriptor_pb2 | pip install | 规划中 |
| **Go** | go-php 解析器 (静态) | protoc 子进程 或 descriptorpb | go install | 规划中 |
| **Rust** | php-parser crate | protoc 子进程 | cargo install | 未来 |

### 为什么 PHP 是参考实现

1. **YAR 本身是 PHP 生态**：YAR Server 用 PHP 编写，PHP 反射能力最强
2. **PHP-Parser 成熟**：nikic/PHP-Parser (17.4k stars) 提供完整的 AST 静态分析
3. **PHP Reflection API 全面**：参数名、类型、默认值、返回类型、文档注释全覆盖
4. **YAR Server 原生内省**：HTTP GET 直接返回方法列表，无需额外工具
5. **可做成 PHP 扩展**：通过 PECL 分发，CLI 模式下安装即用

### PHP 实现的两种形态

```
┌──────────────────────────────────────────────────────────────────┐
│  PHP 实现的两种形态                                                │
│                                                                  │
│  形态 A: 纯 PHP CLI 工具 (Composer 包)                           │
│  ┌────────────────────────────────────────────────────┐          │
│  │ $ composer global require yar/proto-generator      │          │
│  │ $ yar2proto generate ./src/Calculator.php          │          │
│  │     --output=proto/calc.pb                         │          │
│  │                                                    │          │
│  │ 依赖:                                              │          │
│  │ - nikic/php-parser (静态分析)                      │          │
│  │ - symfony/console (CLI 框架)                       │          │
│  │ - protoc (系统安装)                                │          │
│  │                                                    │          │
│  │ 优点: 安装简单，跨平台，无需编译                     │          │
│  │ 缺点: 需要 PHP 运行时，大项目分析较慢                │          │
│  │ 适用: 开发环境，CI/CD pipeline                     │          │
│  └────────────────────────────────────────────────────┘          │
│                                                                  │
│  形态 B: PHP 扩展 (PECL) + CLI 包装                              │
│  ┌────────────────────────────────────────────────────┐          │
│  │ $ pecl install yar_proto_gen                       │          │
│  │ $ yar2proto generate ./src/Calculator.php          │          │
│  │     --output=proto/calc.pb                         │          │
│  │                                                    │          │
│  │ 结构:                                              │          │
│  │ - C 扩展: 核心分析逻辑 (AST 解析 + 类型推断)        │          │
│  │ - PHP CLI: 命令行接口 (symfony/console)            │          │
│  │ - Composer bin: 分发 CLI 入口                      │          │
│  │                                                    │          │
│  │ 优点: 高性能，原生集成，可内联 protoc               │          │
│  │ 缺点: 需编译，平台特定，维护成本高                   │          │
│  │ 适用: 大型项目，生产环境，频繁生成                   │          │
│  └────────────────────────────────────────────────────┘          │
│                                                                  │
│  推荐路线:                                                        │
│  1. 先实现形态 A (纯 PHP)，验证设计正确性                          │
│  2. 性能瓶颈出现时，将核心逻辑迁移到形态 B (扩展)                   │
│  3. 两种形态共享同一 CLI 接口和输出格式                            │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## 思路

### 核心原则

1. **PHP 方法签名 → Protobuf message**：每个 PHP YAR 方法的参数列表生成一个 Request message，返回值生成一个 Response message
2. **命名约定对齐**：message 和 service 的命名遵循 OPM 包运行时的约定映射规则
3. **类型推断**：从 PHP 类型提示（type hints）、PHPDoc 注解、或默认值推断 protobuf 字段类型
4. **一键编译**：工具内部调用 `protoc` 编译 .proto 为 .pb，用户只需提供一个 PHP 文件/目录
5. **两种生成模式**：Mode 1 注解模式（推荐，从源码分析）和 Mode 2 内省模式（已上线服务，从 Server 获取方法列表）
6. **注解驱动**：`@yar-rpc` 标注的函数才生成 proto（Mode 1），`@yar-skip` 显式排除（所有模式）
7. **多语言实现**：工具规范语言无关，各生态用自己最自然的方式实现，PHP 为参考实现
8. **渐进式实现**：先纯 PHP CLI 验证设计，性能瓶颈时转 PHP 扩展 (PECL)

### 命名约定（工具与 OPM 包的契约）

```
┌──────────────────────────────────────────────────────────────────┐
│                  命名约定规则                                     │
│                                                                  │
│  PHP YAR Server:                                                 │
│    class Calculator {                                            │
│        /** @yar-rpc */                                           │
│        function add($a, $b) { ... }                              │
│        /** @yar-rpc */                                           │
│        function getUser($id) { ... }                            │
│    }                                                             │
│                                                                  │
│  生成的 .proto:                                                   │
│    syntax = "proto3";                                            │
│                                                                  │
│    // --- Calculator 服务 ---                                     │
│    message Calculator_AddRequest {                               │
│        int32 a = 1;   // 参数 $a                                 │
│        int32 b = 2;   // 参数 $b                                 │
│    }                                                             │
│    message Calculator_AddResponse {                              │
│        int32 result = 1;  // 标量返回包装为 result 字段           │
│    }                                                             │
│    message Calculator_GetUserRequest {                           │
│        int32 id = 1;    // 参数 $id                              │
│    }                                                             │
│    message Calculator_GetUserResponse {                         │
│        string name = 1;  // 数组返回按 key 映射字段              │
│        int32 age = 2;                                            │
│    }                                                             │
│                                                                  │
│    service Calculator {                                          │
│        rpc Add(Calculator_AddRequest)                           │
│            returns (Calculator_AddResponse);                    │
│        rpc GetUser(Calculator_GetUserRequest)                   │
│            returns (Calculator_GetUserResponse);                │
│    }                                                             │
│                                                                  │
│  gRPC path (客户端调用时):                                       │
│    /Calculator/Add                                              │
│    /Calculator/GetUser                                           │
│                                                                  │
│  OPM 包运行时映射:                                                │
│    services["Calculator"].url → YAR server URL                   │
│    gRPC path "/Calculator/Add" → YAR method "add"               │
│    pb.decode("Calculator_AddRequest", payload) → params        │
│    YAR retval → pb.encode("Calculator_AddResponse", table)     │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 注解约定 (Annotation Convention)

```
┌──────────────────────────────────────────────────────────────────┐
│              PHP 注解约定 (工具与 PHP 代码的契约)                   │
│                                                                  │
│  @yar-rpc     标记函数为 YAR RPC 方法 → 生成 proto               │
│  @yar-skip    标记函数不生成 proto (显式排除)                     │
│  (无注解)     默认不生成 (Mode 1) / 默认生成 (Mode 2)            │
│                                                                  │
│  ────────────────────────────────────────────────────────────── │
│                                                                  │
│  Mode 1 (注解模式，推荐):                                        │
│  ┌────────────────────────────────────────────────────┐          │
│  │ class Calculator {                                │          │
│  │     /**                                           │          │
│  │      * @yar-rpc                                   │          │
│  │      * @param int $a                              │          │
│  │      * @param int $b                              │          │
│  │      * @return int                               │          │
│  │      */                                           │          │
│  │     function add($a, $b) { ... }                 │          │
│  │                                                   │          │
│  │     /**                                           │          │
│  │      * @yar-rpc                                   │          │
│  │      * @param int $id                             │          │
│  │      * @return array{name: string, age: int}     │          │
│  │      */                                           │          │
│  │     function getUser($id) { ... }                │          │
│  │                                                   │          │
│  │     /**                                           │          │
│  │      * @yar-skip  ← 显式排除，不生成 proto          │          │
│  │      */                                           │          │
│  │     function _internalHelper() { ... }           │          │
│  │                                                   │          │
│  │     // 无注解 → Mode 1 下不生成                    │          │
│  │     function utilityMethod() { ... }              │          │
│  │ }                                                 │          │
│  └────────────────────────────────────────────────────┘          │
│                                                                  │
│  Mode 2 (内省模式，已上线服务):                                  │
│  ┌────────────────────────────────────────────────────┐          │
│  │ 从 YAR Server 内省获取方法列表                      │          │
│  │ 所有 public 方法默认生成 proto                      │          │
│  │ @yar-skip 注解的方法被排除                         │          │
│  │                                                   │          │
│  │ 适用场景:                                          │          │
│  │ - 已上线的 YAR 服务，无注解                        │          │
│  │ - 无法获取源码，只有服务地址                       │          │
│  │ - 快速生成所有方法的 proto 骨架                    │          │
│  └────────────────────────────────────────────────────┘          │
│                                                                  │
│  为什么需要 @yar-skip:                                            │
│  Mode 2 会静默包含所有 public 方法                                │
│  @yar-skip 让用户显式排除不应暴露的方法                            │
│  (如内部辅助函数、调试接口等)                                     │
│                                                                  │
│  两种模式可混用:                                                  │
│  Mode 1 开发新服务 → 上线后用 Mode 2 补全 → @yar-skip 排除       │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 类型映射规则

```
┌──────────────────────────────────────────────────────────────────┐
│              PHP 类型 → Protobuf 类型映射                          │
│                                                                  │
│  PHP 类型              │ Protobuf 类型    │ 说明                  │
│  ─────────────────────┼─────────────────┼───────────────────── │
│  int, integer          │ int32            │                      │
│  float, double         │ double           │                      │
│  string                │ string           │                      │
│  bool, boolean         │ bool             │                      │
│  array (索引数组)      │ repeated <type>  │ 需推断元素类型        │
│  array (关联数组)      │ message          │ 生成嵌套 message      │
│  object (stdClass)    │ message          │ 按属性生成字段        │
│  null / void          │ google.protobuf. │ 空响应                 │
│                       │   Empty          │                      │
│  mixed / unknown      │ string           │ 回退为 JSON 字符串    │
│                        │                  │ (保守策略)            │
│                                                                  │
│  特殊处理:                                                       │
│  - int64 / 大整数     │ int64            │ PHP doc 指定时        │
│  - bytes / binary     │ bytes            │ PHP doc 指定时        │
│  - enum (PHP class     │ enum             │ PHP 类常量集合        │
│    const)              │                  │                      │
└──────────────────────────────────────────────────────────────────┘
```

### 参数提取规则

```
┌──────────────────────────────────────────────────────────────────┐
│  Protobuf field number → YAR positional param                    │
│                                                                  │
│  PHP: function add($a, $b)                                      │
│                                                                  │
│  .proto:                                                         │
│  message Calculator_AddRequest {                                │
│      int32 a = 1;  ← field number 1 = 第一个参数 $a              │
│      int32 b = 2;  ← field number 2 = 第二个参数 $b              │
│  }                                                               │
│                                                                  │
│  运行时 (OPM 包):                                                │
│  pb.decode → { a = 1, b = 2 }                                   │
│  按 field number 排序提取: params = { [1]=1, [2]=2 }             │
│  → YAR call: client:call("add", {1, 2})                        │
│  → YAR 协议体: { i=txid, m="add", p={1, 2} }                   │
│  → PHP 端: function add($a, $b) ← $a=1, $b=2                    │
│                                                                  │
│  关键: field number 必须与 PHP 参数顺序一致                        │
│  工具生成 .proto 时保证此约束                                    │
│                                                                  │
│  注意: field name 不参与请求映射 (YAR 是位置参数)                 │
│  field name 仅用于可读性，运行时只看 field number                  │
└──────────────────────────────────────────────────────────────────┘
```

### 字段名映射策略

```
┌──────────────────────────────────────────────────────────────────┐
│              字段名映射策略 (请求 vs 响应)                          │
│                                                                  │
│  请求方向 (gRPC → YAR):                                          │
│  ────────────────────────────────────────────────────────────── │
│  YAR 请求体 p 是位置参数数组，PHP 按位置接收                       │
│  映射依据: field number → 位置索引 (1-based)                      │
│  field name 不参与映射，仅用于可读性                                │
│                                                                  │
│  pb.decode("Calculator_AddRequest", payload) → { a=1, b=2 }    │
│  遍历字段按 number 排序 → params = { [1]=1, [2]=2 }              │
│  → client:call("add", params)                                   │
│                                                                  │
│  响应方向 (YAR → gRPC):                                          │
│  ────────────────────────────────────────────────────────────── │
│  YAR 响应体 r (retval) 的映射取决于返回值类型:                    │
│                                                                  │
│  标量返回 → 包装为单字段:                                         │
│    retval = 3 → { result = 3 } → pb.encode                       │
│                                                                  │
│  关联数组返回 → field name = PHP key:                             │
│    retval = { name="alice", age=18 }                             │
│    Response message: { string name = 1; int32 age = 2; }        │
│    retval 直接作为 message table → pb.encode                      │
│    (field name 与 PHP key 自然对齐)                               │
│                                                                  │
│  索引数组返回 → 包装为 repeated:                                  │
│    retval = { {name="a"}, {name="b"} }                            │
│    Response: { repeated ItemType items = 1; }                    │
│    { items = retval } → pb.encode                                │
│                                                                  │
│  void/null 返回 → google.protobuf.Empty:                         │
│    retval = nil → pb.encode("google.protobuf.Empty", {})        │
│                                                                  │
│  设计决策: 不使用 [json_name] 或 [yar] 标注                      │
│  ────────────────────────────────────────────────────────────── │
│  理由 1: lua-protobuf 不暴露字段选项 (pb.field 无 json_name)     │
│  理由 2: 请求方向是位置参数，field name 不参与映射                 │
│  理由 3: 响应方向用 field name 对齐 PHP key，工具保证命名一致     │
│  理由 4: 边缘情况 (field name 无法匹配 PHP key) 用 sidecar 映射   │
│                                                                  │
│  Sidecar 映射 (可选，处理边缘情况):                               │
│  field_map = {                                                   │
│    ["Calculator_GetUserResponse"] = {                             │
│      user_name = "user_name",  -- 显式指定 YAR key               │
│    }                                                             │
│  }                                                               │
│  运行时优先查 field_map，无则用 field name                        │
└──────────────────────────────────────────────────────────────────┘
```

### 返回值映射规则

```
┌──────────────────────────────────────────────────────────────────┐
│  YAR retval → Protobuf Response message                          │
│                                                                  │
│  情况 1: 标量返回 (int, string, bool, float)                     │
│  PHP: return $a + $b;  → retval = 3                             │
│  .proto: message Xxx_Response { <type> result = 1; }            │
│  运行时: { result = retval } → pb.encode                         │
│                                                                  │
│  情况 2: 关联数组返回 (key-value)                                │
│  PHP: return ["name"=>"alice", "age"=>18]                       │
│  .proto: message Xxx_Response {                                  │
│      string name = 1; int32 age = 2;                            │
│  }                                                               │
│  运行时: retval 直接作为 message table → pb.encode                │
│  (字段名对齐)                                                     │
│                                                                  │
│  情况 3: 索引数组返回 (列表)                                      │
│  PHP: return [["name"=>"alice"], ["name"=>"bob"]]               │
│  .proto: message Xxx_Response {                                  │
│      repeated <ItemType> items = 1;                             │
│  }                                                               │
│  运行时: { items = retval } → pb.encode                          │
│                                                                  │
│  情况 4: 嵌套对象返回                                             │
│  PHP: return ["user"=>["name"=>"alice"], "count"=>1]           │
│  .proto: message Xxx_Response {                                  │
│      UserInfo user = 1;  int32 count = 2;                       │
│  }                                                               │
│  message UserInfo { string name = 1; }                          │
│  运行时: retval 直接作为 message table → pb.encode                │
│  (嵌套 table 自然对齐嵌套 message)                                │
│                                                                  │
│  情况 5: void / null 返回                                        │
│  PHP: return;  或  return null;                                  │
│  .proto: import "google/protobuf/empty.proto";                  │
│  rpc Xxx(...) returns (google.protobuf.Empty);                  │
│  运行时: pb.encode("google.protobuf.Empty", {}) → 空消息        │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## 技术选型分析

### 代码分析方案对比

```
┌──────────────────────────────────────────────────────────────────┐
│              PHP 代码分析方案对比                                   │
│                                                                  │
│  方案           │ nikic/PHP-Parser  │ PHP Reflection API          │
│  ───────────────┼───────────────────┼────────────────────────── │
│  分析方式       │ AST 静态解析       │ 运行时反射                  │
│  需要 PHP 运行时 │ 否 (只需解析器)    │ 是 (需 require 类文件)      │
│  副作用风险     │ 零 (不执行代码)    │ 高 (类文件可能有副作用)      │
│  类型准确性     │ 中 (依赖 PHPDoc)   │ 高 (运行时类型)             │
│  参数名         │ ✅ AST 节点         │ ✅ getName()               │
│  参数类型       │ ✅ 类型提示节点     │ ✅ getType()                │
│  默认值         │ ✅ AST 常量表达式   │ ✅ getDefaultValue()        │
│  返回类型       │ ✅ returnType 节点  │ ✅ getReturnType()          │
│  PHPDoc 注释    │ ✅ 词法分析器属性   │ ✅ getDocComment()          │
│  继承方法       │ 需手动解析继承链   │ ✅ 自动解析                 │
│  PHP 版本支持   │ PHP 7.0-8.4        │ 取决于运行时 PHP 版本       │
│  性能           │ 中 (AST 构建+遍历) │ 高 (C 实现)                 │
│  Stars/成熟度   │ 17.4k ★ / 非常成熟 │ PHP 内置 / 官方             │
│                                                                  │
│  推荐策略:                                                        │
│  - 默认用 PHP-Parser (静态，零副作用)                              │
│  - 需要运行时类型时回退到 Reflection                              │
│  - 两种方式可混用: PHP-Parser 解析结构 + Reflection 补充类型      │
└──────────────────────────────────────────────────────────────────┘
```

### .pb 描述符生成方案对比

```
┌──────────────────────────────────────────────────────────────────┐
│              .pb 二进制描述符生成方案对比                           │
│                                                                  │
│  方案 A: protoc 子进程 (推荐)                                     │
│  ────────────────────────────────────────────────────────────── │
│  $protoc --descriptor_set_out=output.pb \                       │
│           --include_imports input.proto                          │
│                                                                  │
│  优点: 官方工具，兼容性保证，支持所有 proto 特性                   │
│  缺点: 需要系统安装 protoc                                        │
│  适用: 所有场景 (推荐默认方案)                                    │
│                                                                  │
│  方案 B: 编程构造 FileDescriptorSet (无需 protoc)                 │
│  ────────────────────────────────────────────────────────────── │
│  FileDescriptorSet 本身是标准 protobuf 消息                       │
│  可用代码直接构造并序列化为 .pb:                                   │
│                                                                  │
│  PHP: google/protobuf 包 (DescriptorProtos)                     │
│  Python: google.protobuf.descriptor_pb2                         │
│  Go: google.golang.org/protobuf/types/descriptorpb              │
│                                                                  │
│  优点: 无外部依赖，自包含                                         │
│  缺点: 实现复杂，需手动处理所有 proto 特性                        │
│  适用: 不方便安装 protoc 的环境                                   │
│                                                                  │
│  方案 C: protoc 插件 (不适用于本工具)                             │
│  ────────────────────────────────────────────────────────────── │
│  protoc 插件是从 .proto 生成代码的工具                            │
│  本工具是从 PHP 代码生成 .proto，方向相反                         │
│  因此 protoc 插件机制不适用                                      │
│  (但可用 protoc 插件从生成的 .proto 生成 PHP 客户端 stub)        │
│                                                                  │
│  推荐策略:                                                        │
│  - 默认用方案 A (protoc 子进程)                                   │
│  - 未来可选支持方案 B (编程构造) 作为 fallback                     │
└──────────────────────────────────────────────────────────────────┘
```

### YAR Server 内省机制分析

```
┌──────────────────────────────────────────────────────────────────┐
│              YAR Server 内省机制 (基于 laruence/yar 研究)           │
│                                                                  │
│  触发方式: HTTP GET 请求 YAR Server URL                          │
│  返回内容: HTML 页面，列出所有 public 方法及其文档注释              │
│  可见性:   仅 public 方法 (protected/private 不显示)              │
│                                                                  │
│  配置控制:                                                        │
│  - yar.expose_info = On (默认) → 允许 GET 内省                   │
│  - yar.expose_info = Off → 禁止内省                              │
│                                                                  │
│  自定义内省输出 (YAR 2.3.0+):                                     │
│  class API {                                                     │
│      protected function __info($markup) {                        │
│          // $markup 是默认 HTML 内容                               │
│          // 可返回自定义内容 (如 JSON)                             │
│          return json_encode($this->getMethodList());             │
│      }                                                           │
│  }                                                               │
│                                                                  │
│  对工具的影响:                                                    │
│  - Mode 2 内省默认解析 HTML (正则/DOM 解析)                       │
│  - 推荐服务端实现 __info 返回 JSON (结构化数据)                    │
│  - 工具支持 --introspect-format=json 读取结构化内省               │
│  - lua-resty-yar 的 HTTP server 也可扩展支持 JSON 内省输出       │
│                                                                  │
│  内省数据结构 (JSON 模式):                                        │
│  {                                                               │
│    "service": "Calculator",                                      │
│    "methods": [                                                  │
│      {                                                           │
│        "name": "add",                                            │
│        "doc": "@param int $a\n@param int $b\n@return int",      │
│        "params": [                                               │
│          {"name": "a", "type": "int"},                          │
│          {"name": "b", "type": "int"}                            │
│        ],                                                        │
│        "return_type": "int"                                      │
│      }                                                           │
│    ]                                                             │
│  }                                                               │
│                                                                  │
│  注意: PHP YAR 原生内省不包含参数类型 (只有方法名+doc)             │
│  类型信息需从 PHPDoc 解析或从源码补充                              │
└──────────────────────────────────────────────────────────────────┘
```

### PHP 扩展开发选型

```
┌──────────────────────────────────────────────────────────────────┐
│              PHP 扩展开发方案对比 (形态 B)                          │
│                                                                  │
│  方案           │ 原生 C 扩展      │ PHP-CPP        │ Zephir     │
│  ───────────────┼─────────────────┼───────────────┼────────────│
│  语言           │ C                │ C++            │ Zephir     │
│  学习曲线       │ 陡峭             │ 中等           │ 平缓       │
│  性能           │ 最高             │ 高             │ 高         │
│  维护性         │ 较低             │ 中等           │ 较高       │
│  社区支持       │ 最广泛           │ 中等           │ 较小       │
│  适合场景       │ 底层/高性能       │ C++ 开发者     │ PHP 开发者 │
│  分发           │ PECL             │ PECL           │ PECL       │
│                                                                  │
│  扩展 + CLI 最佳实践:                                             │
│  ┌────────────────────────────────────────────┐                  │
│  │ yar_proto_gen/                              │                  │
│  │ ├── ext/                # C 扩展源码        │                  │
│  │ │   ├── config.m4                            │                  │
│  │ │   └── yar_proto_gen.c  # 核心分析逻辑     │                  │
│  │ ├── bin/               # CLI 入口            │                  │
│  │ │   └── yar2proto       # #!/usr/bin/env php│                  │
│  │ ├── src/               # PHP 包装类         │                  │
│  │ │   ├── Generator.php    # .proto 生成       │                  │
│  │ │   └── Analyzer.php     # 调用扩展分析      │                  │
│  │ └── composer.json      # 分发 CLI + 包装    │                  │
│  └────────────────────────────────────┘                          │
│                                                                  │
│  分发方式:                                                        │
│  $ pecl install yar_proto_gen     # 安装扩展                     │
│  $ composer global require yar/proto-gen  # 安装 CLI 包装         │
│  $ yar2proto generate ...         # 使用                         │
│                                                                  │
│  推荐: 先用纯 PHP (形态 A) 验证设计，性能瓶颈时再转扩展 (形态 B)   │
└──────────────────────────────────────────────────────────────────┘
```

## 实现方式

### 工具架构

```
┌──────────────────────────────────────────────────────────────────┐
│                  yar2proto 工具架构 (PHP 参考实现)                  │
│                                                                  │
│  ┌─────────────────────┐    ┌──────────────┐    ┌────────────┐  │
│  │ 输入分析器           │    │ Proto 生成器  │    │ .pb 编译   │  │
│  │                     │    │              │    │            │  │
│  │ ┌─────────────────┐ │    │ 输入:        │    │ 方案 A:    │  │
│  │ │ Mode 1: 源码分析 │ │───▶│ - 方法列表    │───▶│ protoc     │  │
│  │ │ PHP-Parser AST  │ │    │ - 参数类型    │    │ 子进程     │  │
│  │ │ 或 Reflection   │ │    │ - 返回类型    │    │            │  │
│  │ │ @yar-rpc 筛选    │ │    │              │    │ 方案 B:    │  │
│  │ └─────────────────┘ │    │ 输出:        │    │ 编程构造   │  │
│  │ ┌─────────────────┐ │    │ - .proto     │    │ Descriptor │  │
│  │ │ Mode 2: 内省    │ │    │   文本        │    │ (可选)     │  │
│  │ │ HTTP GET → HTML │ │    │              │    │            │  │
│  │ │ 或 __info→JSON  │ │    │              │    │ 输出:      │  │
│  │ └─────────────────┘ │    │              │    │ - .pb 二进制│  │
│  │ ┌─────────────────┐ │    │              │    │ - .proto   │  │
│  │ │ 混合: 源码+内省  │ │    │              │    │   (可选)   │  │
│  │ │ 方法列表←内省    │ │    │              │    │            │  │
│  │ │ 类型←源码PHPDoc │ │    │              │    │            │  │
│  │ └─────────────────┘ │    │              │    │            │  │
│  └─────────────────────┘    └──────────────┘    └────────────┘  │
│                                                                  │
│  PHP 实现形态:                                                   │
│  ┌─────────────────────────────────────────────────────┐        │
│  │ 形态 A (优先): 纯 PHP CLI (Composer 包)              │        │
│  │   依赖: nikic/php-parser + symfony/console + protoc  │        │
│  │   安装: composer global require yar/proto-generator  │        │
│  └─────────────────────────────────────────────────────┘        │
│  ┌─────────────────────────────────────────────────────┐        │
│  │ 形态 B (未来): PHP 扩展 (PECL) + CLI 包装             │        │
│  │   结构: C 扩展 (核心分析) + PHP CLI (命令接口)         │        │
│  │   安装: pecl install yar_proto_gen                    │        │
│  │         + composer global require yar/proto-gen       │        │
│  └─────────────────────────────────────────────────────┘        │
│                                                                  │
│  其他语言实现:                                                    │
│  Python: pip install yar2proto  (php-parser + protoc)          │
│  Go: go install yar2proto       (go-php + protoc)               │
│  各实现共享同一规范，输出格式完全一致                              │
└──────────────────────────────────────────────────────────────────┘
```

### PHP 分析器

#### Mode 1: 注解模式 (推荐)

```
┌──────────────────────────────────────────────────────────────────┐
│  Mode 1: 注解模式 — 从 PHP 源码分析                                │
│                                                                  │
│  输入: PHP 源码文件/目录                                          │
│  原则: 只生成带 @yar-rpc 注解的函数                                │
│  @yar-skip 注解的函数显式排除                                      │
│                                                                  │
│  分析策略 (按优先级):                                             │
│                                                                  │
│  策略 1: PHP-Parser 静态分析 (推荐，零副作用)                     │
│  ┌────────────────────────────────────────────────────┐          │
│  │ 使用 nikic/PHP-Parser (17.4k ★, BSD-3)             │          │
│  │ 将 PHP 源码解析为 AST，不执行任何代码                │          │
│  │                                                    │          │
│  │ $parser = (new ParserFactory())                    │          │
│  │   ->createForNewestSupportedVersion();             │          │
│  │ $ast = $parser->parse(file_get_contents($file));   │          │
│  │                                                    │          │
│  │ 遍历 AST 节点:                                      │          │
│  │ - Stmt\Class_ → 类名、方法列表                      │          │
│  │ - Stmt\ClassMethod → 方法名、参数、返回类型          │          │
│  │ - Param → 参数名、类型提示、默认值                  │          │
│  │ - Lexer attributes → PHPDoc 注释                   │          │
│  │                                                    │          │
│  │ 支持: PHP 7.0-8.4, 类型提示, PHPDoc, 默认值        │          │
│  │ 优点: 零副作用, 不需要 PHP 运行时, 跨版本兼容       │          │
│  │ 缺点: 无法获取运行时类型, 继承链需手动解析           │          │
│  └────────────────────────────────────────────────────┘          │
│                                                                  │
│  策略 2: 运行时反射 (补充，最准确)                                │
│  ┌────────────────────────────────────────────────────┐          │
│  │ $ref = new ReflectionClass('Calculator');          │          │
│  │ foreach ($ref->getMethods() as $method) {           │          │
│  │     $doc = $method->getDocComment();               │          │
│  │     if (!preg_match('/@yar-rpc/', $doc)) continue; │          │
│  │     if (preg_match('/@yar-skip/', $doc)) continue;│          │
│  │     $params = $method->getParameters();            │          │
│  │     // $param->getName() → 参数名                  │          │
│  │     // $param->getType() → 类型提示 (PHP 7+)       │          │
│  │     // $param->getDefaultValue() → 默认值           │          │
│  │ }                                                  │          │
│  │ $returnType = $method->getReturnType();            │          │
│  └────────────────────────────────────────────────────┘          │
│  优点: 100% 准确，自动解析继承链                                   │
│  缺点: 需要 PHP 运行时，类文件不能有副作用                         │
│  适用: 类文件无副作用时的补充类型获取                              │
│                                                                  │
│  策略 3: PHPDoc 注解解析 (补充类型信息)                           │
│  ┌────────────────────────────────────────────────────┐          │
│  │ 从 PHP-Parser 或 Reflection 获取 doc comment       │          │
│  │ 解析 @param, @return 注解获取类型                   │          │
│  │                                                    │          │
│  │ /**                                                │          │
│  │  * @yar-rpc                                        │          │
│  │  * @param int $a                                   │          │
│  │  * @param int $b                                   │          │
│  │  * @return int                                     │          │
│  │  */                                                │          │
│  │ → 适用于无类型提示的老代码                          │          │
│  └────────────────────────────────────────────────────┘          │
│                                                                  │
│  策略 4: 默认值推断 (兜底)                                        │
│  ┌────────────────────────────────────────────────────┐          │
│  │ function greet($name = "world") { ... }            │          │
│  │ → 默认值 "world" 是 string → 参数类型 string        │          │
│  │                                                    │          │
│  │ function setPort($port = 8080) { ... }            │          │
│  │ → 默认值 8080 是 int → 参数类型 int32              │          │
│  └────────────────────────────────────────────────────┘          │
│                                                                  │
│  回退: 无法推断类型时 → string (保守，JSON 序列化兼容)             │
│                                                                  │
│  推荐组合:                                                        │
│  PHP-Parser (结构+注解) → Reflection (运行时类型) → 默认值 → string│
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

#### Mode 2: 内省模式 (已上线服务)

```
┌──────────────────────────────────────────────────────────────────┐
│  Mode 2: 内省模式 — 从运行中的 YAR Server 获取方法列表            │
│                                                                  │
│  输入: YAR Server URL                                             │
│  原则: 所有 public 方法默认生成 proto                             │
│  @yar-skip 注解的方法被排除 (需配合源码)                           │
│                                                                  │
│  适用场景:                                                        │
│  - 已上线的 YAR 服务，无 @yar-rpc 注解                            │
│  - 无法获取源码，只有服务地址                                     │
│  - 快速生成所有方法的 proto 骨架                                  │
│                                                                  │
│  内省机制 (基于 laruence/yar 研究):                               │
│  ┌────────────────────────────────────────────────────┐          │
│  │ 方式 A: HTTP GET 内省 (YAR 原生)                    │          │
│  │                                                    │          │
│  │ YAR Server 原生支持 HTTP GET 内省:                  │          │
│  │ GET http://127.0.0.1:8888/api                      │          │
│  │ → 返回 HTML 页面，列出所有 public 方法              │          │
│  │   及其 PHPDoc 文档注释                              │          │
│  │                                                    │          │
│  │ 配置控制:                                           │          │
│  │ - yar.expose_info = On (默认) → 允许内省           │          │
│  │ - yar.expose_info = Off → 禁止内省                 │          │
│  │                                                    │          │
│  │ 可见性: 仅 public 方法 (protected/private 不显示)   │          │
│  │                                                    │          │
│  │ 工具解析: 正则或 DOM 解析 HTML 提取方法列表         │          │
│  │ 缺点: HTML 格式不稳定，类型信息有限                  │          │
│  └────────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌────────────────────────────────────────────────────┐          │
│  │ 方式 B: __info 魔术方法 (YAR 2.3.0+, 推荐)          │          │
│  │                                                    │          │
│  │ YAR 2.3.0+ 支持自定义内省输出:                       │          │
│  │ class API {                                        │          │
│  │     protected function __info($markup) {            │          │
│  │         // $markup 是默认 HTML 内容                  │          │
│  │         return json_encode([                        │          │
│  │             'service' => 'Calculator',              │          │
│  │             'methods' => $this->getMethodList()     │          │
│  │         ]);                                         │          │
│  │     }                                               │          │
│  │ }                                                   │          │
│  │                                                    │          │
│  │ 工具请求时加 Accept: application/json               │          │
│  │ 或 ?format=json 参数                                │          │
│  │ → 获取结构化 JSON 方法列表                          │          │
│  │                                                    │          │
│  │ 优点: 结构化数据，类型信息丰富                       │          │
│  │ 缺点: 需服务端实现 __info 方法                       │          │
│  └────────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌────────────────────────────────────────────────────┐          │
│  │ 方式 C: 源码 + 内省混合                             │          │
│  │                                                    │          │
│  │ 有源码但不想逐个加 @yar-rpc 注解:                    │          │
│  │ 1. 从 YAR Server 内省获取方法列表 (方法名+参数)     │          │
│  │ 2. 从源码用 PHP-Parser 读取 PHPDoc 获取类型信息      │          │
│  │ 3. @yar-skip 注解的方法被排除                       │          │
│  │                                                    │          │
│  │ 优点: 无需逐个加注解，又能获取准确类型               │          │
│  └────────────────────────────────────────────────────┘          │
│                                                                  │
│  类型推断 (Mode 2 的挑战):                                       │
│  YAR 原生内省只返回方法名+PHPDoc，无运行时类型                    │
│  → 方式 B 的 __info 可包含类型 (需服务端配合)                     │
│  → 方式 C 从源码用 PHP-Parser 补充类型                           │
│  → 无法获取类型时回退为 string (保守策略)                         │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

#### 两种模式对比

```
┌──────────────────────────────────────────────────────────────────┐
│                    Mode 1 vs Mode 2 对比                          │
│                                                                  │
│  维度        │ Mode 1 (注解模式)    │ Mode 2 (内省模式)          │
│  ────────────┼──────────────────────┼─────────────────────────── │
│  输入        │ PHP 源码文件/目录     │ YAR Server URL             │
│  生成范围    │ 仅 @yar-rpc 标注的    │ 所有 public 方法           │
│  排除机制    │ @yar-skip + 默认不生成│ @yar-skip (需配合源码)     │
│  类型准确性  │ 高 (PHP-Parser+反射) │ 中 (取决于内省能力)         │
│  分析方式    │ PHP-Parser AST       │ HTTP GET / __info JSON     │
│  副作用风险  │ 零 (静态分析)         │ 无 (HTTP 请求)              │
│  适用场景    │ 新项目开发            │ 已上线服务                  │
│  需要 PHP    │ 是 (解析器) 或否     │ 否 (HTTP Client 即可)      │
│  需要 YAR    │ 否                   │ 是 (服务必须在线)           │
│  Server 在线 │                      │                            │
│  推荐度      │ ★★★★★ (首选)       │ ★★★☆ (存量迁移)           │
│                                                                  │
│  混合使用:                                                        │
│  1. 新服务用 Mode 1 开发                                          │
│  2. 上线后用 Mode 2 补全遗漏的方法                                │
│  3. @yar-skip 统一管理排除项                                      │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 返回值类型分析

```
┌──────────────────────────────────────────────────────────────────┐
│  返回值类型推断 (最困难的部分)                                     │
│                                                                  │
│  策略 1: PHPDoc @return 注解 (主要)                              │
│  /**                                                              │
│   * @return array{name: string, age: int}                        │
│   */                                                              │
│  function getUser($id)                                           │
│  → 解析 list/shape 注解生成嵌套 message                          │
│                                                                  │
│  策略 2: 类型提示 (PHP 7.4+)                                      │
│  function getUser(): array { ... }                               │
│  → array 太宽泛，需配合 PHPDoc 或运行时采样                        │
│                                                                  │
│  策略 3: 运行时采样 (高级)                                        │
│  工具实际调用 YAR Server，记录返回值结构                           │
│  → 根据实际返回值推断类型                                         │
│  → 适合无文档的遗留代码                                           │
│  → 需要可用的 YAR Server 实例                                    │
│                                                                  │
│  策略 4: 用户手动 .proto 补充                                     │
│  工具生成骨架 .proto，用户手动修正返回值类型                       │
│  → 最可靠，但需要人工参与                                         │
│  → 工具支持 --interactive 模式交互式确认                          │
│                                                                  │
│  推荐组合: PHPDoc 优先 → 类型提示 → 默认值 → 回退 string          │
│           + --interactive 模式让用户确认不确定的类型               │
└──────────────────────────────────────────────────────────────────┘
```

### 工具命令行接口

```
┌──────────────────────────────────────────────────────────────────┐
│  yar2proto 命令行接口                                              │
│                                                                  │
│  === Mode 1: 注解模式 (推荐) ===                                 │
│                                                                  │
│  从 PHP 源码生成 (只处理 @yar-rpc 标注的函数):                   │
│  $ yar2proto generate ./src/Calculator.php \                      │
│      --output=./proto/calc.pb \                                   │
│      --keep-proto                                                 │
│                                                                  │
│  分析整个目录:                                                    │
│  $ yar2proto generate ./src/ \                                    │
│      --output=./proto/ \                                          │
│      --keep-proto                                                 │
│                                                                  │
│  交互模式 (确认不确定的类型):                                     │
│  $ yar2proto generate ./src/Calculator.php \                      │
│      --output=./proto/calc.pb \                                   │
│      --interactive                                                │
│                                                                  │
│  === Mode 2: 内省模式 (已上线服务) ===                           │
│                                                                  │
│  从 YAR Server URL 内省获取方法列表:                              │
│  $ yar2proto generate --server=http://127.0.0.1:8888/api \       │
│      --service=Calculator \                                       │
│      --output=./proto/calc.pb                                     │
│                                                                  │
│  指定非 HTML 文档格式 (需服务端支持):                             │
│  $ yar2proto generate --server=http://127.0.0.1:8888/api \       │
│      --service=Calculator \                                       │
│      --introspect-format=json \                                   │
│      --output=./proto/calc.pb                                     │
│                                                                  │
│  === 混合模式 ===                                                 │
│                                                                  │
│  从源码获取类型 + 从 Server 获取方法列表:                         │
│  $ yar2proto generate ./src/Calculator.php \                      │
│      --server=http://127.0.0.1:8888/api \                        │
│      --output=./proto/calc.pb                                     │
│  → 以 Server 内省的方法列表为准，类型从源码 PHPDoc 补充           │
│  → @yar-skip 的方法被排除                                        │
│                                                                  │
│  参数:                                                            │
│    --output=<path>          输出 .pb 文件路径                    │
│    --keep-proto             同时保留 .proto 文本文件             │
│    --interactive            交互模式，确认不确定的类型            │
│    --server=<url>           YAR Server URL (启用 Mode 2)        │
│    --service=<name>         指定服务名 (默认取类名)              │
│    --introspect-format=<f>  内省响应格式: html|json (默认 html)  │
│    --analyzer=<type>        分析器: parser|reflection|auto       │
│                              parser: PHP-Parser 静态分析 (默认)  │
│                              reflection: 运行时反射 (最准确)    │
│                              auto: parser 优先, 回退 reflection  │
│    --pb-mode=<mode>         .pb 生成方式: protoc|programmatic   │
│                              protoc: 调用 protoc 子进程 (默认)  │
│                              programmatic: 编程构造 (无需 protoc)│
│    --protoc=<path>          protoc 编译器路径 (默认从 PATH 查找) │
│    --php=<path>             PHP 可执行文件路径 (默认从 PATH)     │
│    --mode=<mode>            强制模式: annotate|introspect|hybrid│
│                              (默认自动推断)                      │
│                                                                  │
│  模式自动推断规则:                                                │
│  - 有 PHP 源码参数 + 无 --server → Mode 1 (注解模式)            │
│  - 有 --server + 无源码参数 → Mode 2 (内省模式)                 │
│  - 有源码参数 + 有 --server → 混合模式                           │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## 最佳实践

### 1. 开发工作流

```
┌──────────────────────────────────────────────────────────────────┐
│                  推荐开发工作流                                     │
│                                                                  │
│  1. 编写 PHP YAR Server                                          │
│     ┌────────────────────────────────┐                           │
│     │ // src/Calculator.php          │                           │
│     │ class Calculator {              │                           │
│     │     /**                         │                           │
│     │      * @yar-rpc                 │                           │
│     │      * @param int $a            │                           │
│     │      * @param int $b            │                           │
│     │      * @return int              │                           │
│     │      */                         │                           │
│     │     function add($a, $b) {     │                           │
│     │         return $a + $b;         │                           │
│     │     }                          │                           │
│     │ }                              │                           │
│     └────────────────────────────────┘                           │
│                                                                  │
│  2. 生成 .pb 文件                                                 │
│     $ yar2proto generate src/Calculator.php \                     │
│         --output=proto/calc.pb --keep-proto                      │
│     → 生成 proto/calc.pb 和 proto/calc.proto                     │
│                                                                  │
│  3. 配置 OpenResty                                                │
│     nginx.conf:                                                   │
│     ┌────────────────────────────────┐                           │
│     │ lua_package_path ";;";         │                           │
│     │                                │                           │
│     │ init_by_lua_block {            │                           │
│     │   require("resty.grpc_yar_proxy")│                          │
│     │   .setup {                    │                           │
│     │     services = {              │                           │
│     │       Calculator = {          │                           │
│     │         proto = "proto/calc.pb"│                         │
│     │         url =                 │                           │
│     │       "http://127.0.0.1:8888/api"│                      │
│     │       }                       │                           │
│     │     }                         │                           │
│     │   }                           │                           │
│     │ }                             │                           │
│     │                                │                           │
│     │ server {                       │                           │
│     │   listen 50051 http2;          │                           │
│     │   location / {                 │                           │
│     │     content_by_lua_block {     │                           │
│     │       require("resty.grpc_yar_ │                           │
│     │       proxy").serve()          │                           │
│     │     }                         │                           │
│     │   }                           │                           │
│     │ }                             │                           │
│     └────────────────────────────────┘                           │
│                                                                  │
│  4. gRPC 客户端调用                                               │
│     使用生成的 .proto 文件编译客户端 stub                         │
│     调用: Calculator.Add(a=1, b=2) → result=3                   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 2. 类型提示最佳实践

```php
<?php
// 推荐：使用 @yar-rpc 注解 + PHPDoc 类型注解
class UserService {
    /**
     * @yar-rpc
     * @param int $id 用户ID
     * @return array{name: string, age: int, email: string}
     */
    function getUser($id) {
        return [
            "name" => "alice",
            "age" => 18,
            "email" => "alice@example.com",
        ];
    }

    /**
     * @yar-rpc
     * @return array<int, array{name: string}>
     *   返回用户列表
     */
    function listUsers() {
        return [
            ["name" => "alice"],
            ["name" => "bob"],
        ];
    }

    /**
     * @yar-rpc
     * @param string $name
     * @param int $age
     * @return bool
     */
    function createUser($name, $age) {
        return true;
    }

    /**
     * @yar-skip  ← 不生成 proto，不对外暴露
     */
    function _internalHelper() {
        // 内部辅助方法
    }
}
```

**注解使用要点**：
- `@yar-rpc`：标记函数为 YAR RPC 方法，工具生成对应 proto
- `@yar-skip`：显式排除函数，所有模式下都不生成
- 无注解：Mode 1 下不生成，Mode 2 下默认生成（可加 `@yar-skip` 排除）
- `@param`/`@return`：PHPDoc 类型注解，帮助工具准确推断 protobuf 类型

### 3. 增量更新

```
┌──────────────────────────────────────────────────────────────────┐
│  PHP 代码变更后的更新流程                                          │
│                                                                  │
│  1. 修改 PHP YAR Server 代码                                     │
│  2. 重新运行 yar2proto 生成 .pb                                   │
│     $ yar2proto generate src/Calculator.php --output=proto/calc.pb│
│  3. reload OpenResty (init_by_lua 重新加载 .pb)                   │
│     $ nginx -s reload                                             │
│  4. gRPC 客户端重新编译 stub (如果 .proto 变了)                   │
│                                                                  │
│  CI/CD 集成:                                                      │
│  - git hook: PHP 文件变更时自动重新生成 .pb                       │
│  - CI pipeline: 构建阶段运行 yar2proto                            │
│  - 版本控制: .pb 文件提交到 git (二进制 LFS)                      │
│    或 .proto 文件提交到 git，CI 时编译 .pb                         │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 4. 版本兼容性

```
┌──────────────────────────────────────────────────────────────────┐
│  .proto 版本管理                                                   │
│                                                                  │
│  - 字段只增不删：新增字段用新 field number，不回收旧编号            │
│  - 类型兼容：int32 → int64 兼容，反向不兼容                       │
│  - 工具生成时记录 field number 分配历史，避免冲突                 │
│  - .proto 文件中保留注释标记字段版本                               │
│                                                                  │
│  message Calculator_AddRequest {                                  │
│      int32 a = 1;  // v1                                         │
│      int32 b = 2;  // v1                                         │
│      int32 c = 3;  // v2 新增                                     │
│      // string note = 4;  // v3 计划新增 (reserved)              │
│  }                                                               │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 5. 安全注意事项

```
┌──────────────────────────────────────────────────────────────────┐
│  安全注意事项                                                     │
│                                                                  │
│  Mode 1 (注解模式):                                              │
│  - 工具不应执行 PHP 文件中的副作用代码                             │
│    (require 类文件时避免触发数据库连接等)                          │
│    → 推荐使用 php-parser 静态分析而非运行时反射                    │
│    → 或运行时反射时用 --no-execute 模式隔离                       │
│                                                                  │
│  Mode 2 (内省模式):                                              │
│  - 内省请求不应携带敏感凭证                                       │
│    (token/auth 信息不应出现在工具命令行参数中)                     │
│  - 内省连接应使用内网地址                                         │
│    (避免通过公网暴露 YAR Server 方法列表)                         │
│  - 工具不应缓存内省结果到共享存储                                  │
│    (方法列表可能包含内部接口信息)                                 │
│                                                                  │
│  通用:                                                            │
│  - .pb 文件不应包含敏感信息                                       │
│    (protobuf 描述符只有类型定义，无数据)                           │
│  - YAR Server URL 不应硬编码在 .proto 中                          │
│    (services 在 OpenResty 配置中管理)                           │
│  - @yar-skip 标注的内部方法不应出现在 .proto 中                   │
│    (工具必须严格遵守排除规则)                                     │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## 与 OPM 包的契约总结

```
┌──────────────────────────────────────────────────────────────────┐
│              工具与 OPM 包的约定契约                                │
│                                                                  │
│  工具保证:                                                       │
│  1. Service 名 = PHP 类名 (去 namespace 前缀)                    │
│  2. RPC 名 = PHP 方法名 (首字母大写, protobuf 惯例)              │
│  3. Request message 名 = "{Service}_{Method}Request"            │
│  4. Response message 名 = "{Service}_{Method}Response"           │
│  5. Request field number = PHP 参数顺序 (1-based)                │
│  6. Request field name = PHP 参数名 (小写，仅可读性)              │
│  7. 标量返回 → Response 有单个 "result" 字段 (field 1)           │
│  8. 关联数组返回 → Response field name = PHP 数组 key (小写)     │
│  9. .pb 文件用 protoc --descriptor_set_out --include_imports 编译│
│ 10. @yar-rpc 标注的函数才生成 (Mode 1)                           │
│ 11. @yar-skip 标注的函数不生成 (所有模式)                        │
│                                                                  │
│  OPM 包运行时:                                                   │
│  1. 加载 .pb → pb 模块注册所有 message 类型                       │
│  2. gRPC path "/{Service}/{Method}" → 查 services 得 YAR URL  │
│  3. YAR method = Method 名首字母小写 (对齐 PHP 方法名惯例)       │
│  4. pb.decode("{Service}_{Method}Request", payload) → table     │
│  5. 按 field number 排序提取 params → YAR call(method, params)   │
│     (field name 不参与请求映射，YAR 是位置参数)                   │
│  6. YAR retval → 映射为 Response message table → pb.encode       │
│     (标量 → {result=retval}, 关联数组 → field name 对齐 key)     │
│  7. 可选 field_map sidecar 覆盖响应字段名映射                     │
│                                                                  │
│  字段名映射策略:                                                  │
│  - 请求: field number → 位置参数 (name 不参与)                   │
│  - 响应: field name (小写) → PHP key (默认)                      │
│  - 响应: field_map sidecar → 显式覆盖 (可选)                     │
│  - 不使用 [json_name] 或 [yar] 标注 (lua-protobuf 不暴露)        │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## 示例 PHP YAR Server

以下示例贯穿全文，用于演示两种实现形态的完整流程。

```php
<?php
// src/Calculator.php — 示例 YAR Server

class Calculator
{
    /**
     * 两数相加
     *
     * @yar-rpc
     * @param int $a
     * @param int $b
     * @return int
     */
    public function add($a, $b)
    {
        return $a + $b;
    }

    /**
     * 获取用户信息
     *
     * @yar-rpc
     * @param int $id 用户ID
     * @return array{name: string, age: int, email: string}
     */
    public function getUser($id)
    {
        return [
            'name'  => 'alice',
            'age'   => 18,
            'email' => 'alice@example.com',
        ];
    }

    /**
     * 批量查询用户
     *
     * @yar-rpc
     * @param array<int> $ids
     * @return array<int, array{name: string, age: int}>
     */
    public function batchGetUsers($ids)
    {
        $result = [];
        foreach ($ids as $id) {
            $result[] = ['name' => 'user' . $id, 'age' => 20 + $id];
        }
        return $result;
    }

    /**
     * 创建用户
     *
     * @yar-rpc
     * @param string $name
     * @param int $age
     * @param string $email
     * @return bool
     */
    public function createUser($name, $age, $email)
    {
        // ... 写库逻辑 ...
        return true;
    }

    /**
     * 无返回值操作
     *
     * @yar-rpc
     * @param int $id
     * @return void
     */
    public function deleteUser($id)
    {
        // ... 删除逻辑 ...
    }

    /**
     * @yar-skip  内部方法，不对外暴露
     */
    public function _internalHelper()
    {
        return 'secret';
    }

    // 无注解 → Mode 1 下不生成 proto
    public function utilityMethod()
    {
        return 'utility';
    }
}
```

对应的 `.proto` 期望输出：

```protobuf
syntax = "proto3";

import "google/protobuf/empty.proto";

// --- Calculator 服务 ---

message Calculator_AddRequest {
    int32 a = 1;
    int32 b = 2;
}
message Calculator_AddResponse {
    int32 result = 1;
}

message Calculator_GetUserRequest {
    int32 id = 1;
}
message Calculator_GetUserResponse {
    string name  = 1;
    int32  age   = 2;
    string email = 3;
}

message Calculator_BatchGetUsersRequest {
    repeated int32 ids = 1;
}
message Calculator_BatchGetUsersResponse {
    repeated Calculator_BatchGetUsersResponse_User items = 1;
}
message Calculator_BatchGetUsersResponse_User {
    string name = 1;
    int32  age  = 2;
}

message Calculator_CreateUserRequest {
    string name  = 1;
    int32  age   = 2;
    string email = 3;
}
message Calculator_CreateUserResponse {
    bool result = 1;
}

message Calculator_DeleteUserRequest {
    int32 id = 1;
}
// void 返回 → google.protobuf.Empty

service Calculator {
    rpc Add          (Calculator_AddRequest)          returns (Calculator_AddResponse);
    rpc GetUser      (Calculator_GetUserRequest)       returns (Calculator_GetUserResponse);
    rpc BatchGetUsers(Calculator_BatchGetUsersRequest) returns (Calculator_BatchGetUsersResponse);
    rpc CreateUser   (Calculator_CreateUserRequest)    returns (Calculator_CreateUserResponse);
    rpc DeleteUser   (Calculator_DeleteUserRequest)    returns (google.protobuf.Empty);
}
```

---

## 形态 A: 纯 PHP CLI 工具实现 (Composer 包)

### 项目结构

```
yar2proto/
├── composer.json
├── bin/
│   └── yar2proto                 # #!/usr/bin/env php  CLI 入口
├── src/
│   ├── Application.php           # symfony/console Application
│   ├── Command/
│   │   └── GenerateCommand.php   # generate 子命令
│   ├── Analyzer/
│   │   ├── AnalyzerInterface.php # 分析器接口
│   │   ├── PhpParserAnalyzer.php # Mode 1: PHP-Parser 静态分析
│   │   ├── IntrospectionAnalyzer.php # Mode 2: HTTP 内省
│   │   └── HybridAnalyzer.php    # 混合模式
│   ├── TypeMapper.php            # PHP 类型 → Protobuf 类型映射
│   ├── Generator/
│   │   ├── ProtoGenerator.php    # .proto 文本生成
│   │   └── MessageBuilder.php    # message/service 构造
│   ├── Compiler/
│   │   ├── PbCompilerInterface.php
│   │   ├── ProtocCompiler.php    # 方案 A: protoc 子进程
│   │   └── ProgrammaticCompiler.php # 方案 B: 编程构造
│   └── Model/
│       ├── ServiceInfo.php       # 服务信息模型
│       ├── MethodInfo.php        # 方法信息模型
│       └── ParamInfo.php         # 参数信息模型
└── tests/
    └── ...
```

### composer.json

```json
{
    "name": "yar/proto-generator",
    "description": "Generate gRPC .proto/.pb from PHP YAR Server code",
    "type": "library",
    "license": "Apache-2.0",
    "require": {
        "php": ">=7.4",
        "nikic/php-parser": "^5.0",
        "symfony/console": "^6.0 || ^7.0",
        "guzzlehttp/guzzle": "^7.0",
        "webmozart/assert": "^1.11"
    },
    "require-dev": {
        "phpunit/phpunit": "^10.0"
    },
    "autoload": {
        "psr-4": {
            "Yar\\ProtoGenerator\\": "src/"
        }
    },
    "bin": ["bin/yar2proto"]
}
```

### bin/yar2proto — CLI 入口

```php
#!/usr/bin/env php
<?php
require __DIR__ . '/../vendor/autoload.php';

use Yar\ProtoGenerator\Application;

$application = new Application();
$application->run();
```

### src/Application.php

```php
<?php
namespace Yar\ProtoGenerator;

use Symfony\Component\Console\Application as ConsoleApplication;

class Application extends ConsoleApplication
{
    public function __construct()
    {
        parent::__construct('yar2proto', '1.0.0');
        $this->add(new Command\GenerateCommand());
    }
}
```

### src/Command/GenerateCommand.php

```php
<?php
namespace Yar\ProtoGenerator\Command;

use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\{InputArgument, InputInterface, InputOption};
use Symfony\Component\Console\Output\OutputInterface;
use Yar\ProtoGenerator\Analyzer\PhpParserAnalyzer;
use Yar\ProtoGenerator\Analyzer\IntrospectionAnalyzer;
use Yar\ProtoGenerator\Analyzer\HybridAnalyzer;
use Yar\ProtoGenerator\Generator\ProtoGenerator;
use Yar\ProtoGenerator\Compiler\ProtocCompiler;

class GenerateCommand extends Command
{
    protected static $defaultName = 'generate';

    protected function configure(): void
    {
        $this
            ->setDescription('Generate .proto/.pb from PHP YAR Server code')
            ->addArgument('source', InputArgument::OPTIONAL, 'PHP source file or directory')
            ->addOption('output', 'o', InputOption::VALUE_REQUIRED, 'Output .pb file path')
            ->addOption('keep-proto', null, InputOption::VALUE_NONE, 'Also keep .proto text file')
            ->addOption('interactive', 'i', InputOption::VALUE_NONE, 'Interactive mode for uncertain types')
            ->addOption('server', 's', InputOption::VALUE_OPTIONAL, 'YAR Server URL (enable Mode 2)')
            ->addOption('service', null, InputOption::VALUE_OPTIONAL, 'Service name (default: class name)')
            ->addOption('introspect-format', null, InputOption::VALUE_OPTIONAL, 'Introspect format: html|json', 'html')
            ->addOption('analyzer', null, InputOption::VALUE_OPTIONAL, 'Analyzer: parser|reflection|auto', 'parser')
            ->addOption('pb-mode', null, InputOption::VALUE_OPTIONAL, 'PB generation: protoc|programmatic', 'protoc')
            ->addOption('protoc', null, InputOption::VALUE_OPTIONAL, 'Path to protoc binary');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $source = $input->getArgument('source');
        $serverUrl = $input->getOption('server');

        // 1. 选择分析器 (模式自动推断)
        $analyzer = $this->createAnalyzer($source, $serverUrl, $input->getOptions());

        // 2. 分析 → ServiceInfo[]
        $services = $analyzer->analyze($source, $input->getOption('service'));
        if (empty($services)) {
            $output->writeln('<error>No @yar-rpc methods found.</error>');
            return Command::FAILURE;
        }

        // 3. 生成 .proto 文本
        $generator = new ProtoGenerator();
        $protoText = $generator->generate($services);

        // 4. 编译 .pb
        $compiler = new ProtocCompiler($input->getOption('protoc'));
        $pbFile = $input->getOption('output');
        $compiler->compile($protoText, $pbFile, $input->getOption('keep-proto'));

        $output->writeln("<info>Generated: {$pbFile}</info>");
        return Command::SUCCESS;
    }

    private function createAnalyzer(?string $source, ?string $serverUrl, array $opts): object
    {
        if ($source && $serverUrl) {
            return new HybridAnalyzer($source, $serverUrl, $opts);
        }
        if ($serverUrl) {
            return new IntrospectionAnalyzer($serverUrl, $opts);
        }
        return new PhpParserAnalyzer($opts);
    }
}
```

### src/Analyzer/AnalyzerInterface.php

```php
<?php
namespace Yar\ProtoGenerator\Analyzer;

use Yar\ProtoGenerator\Model\ServiceInfo;

interface AnalyzerInterface
{
    /**
     * @return ServiceInfo[]
     */
    public function analyze(?string $source, ?string $serviceName = null): array;
}
```

### src/Analyzer/PhpParserAnalyzer.php — Mode 1 核心分析器

```php
<?php
namespace Yar\ProtoGenerator\Analyzer;

use PhpParser\{NodeTraverser, NodeVisitorAbstract, ParserFactory};
use PhpParser\Node;
use Yar\ProtoGenerator\Model\{ServiceInfo, MethodInfo, ParamInfo};
use Yar\ProtoGenerator\TypeMapper;

class PhpParserAnalyzer implements AnalyzerInterface
{
    private TypeMapper $typeMapper;

    public function __construct(array $opts = [])
    {
        $this->typeMapper = new TypeMapper();
    }

    public function analyze(?string $source, ?string $serviceName = null): array
    {
        if (!$source) {
            return [];
        }

        $files = is_dir($source) ? $this->findPhpFiles($source) : [$source];
        $services = [];

        foreach ($files as $file) {
            $services = array_merge($services, $this->analyzeFile($file, $serviceName));
        }

        return $services;
    }

    private function analyzeFile(string $file, ?string $serviceName): array
    {
        $code = file_get_contents($file);
        $parser = (new ParserFactory())->createForNewestSupportedVersion();
        $ast = $parser->parse($code);

        $traverser = new NodeTraverser();
        $visitor = new class($this->typeMapper, $serviceName) extends NodeVisitorAbstract {
            private array $services = [];

            public function __construct(
                private TypeMapper $typeMapper,
                private ?string $filterService
            ) {}

            public function leaveNode(Node $node): ?int
            {
                if (!$node instanceof Node\Stmt\Class_) {
                    return null;
                }

                $className = $node->name->name;
                if ($this->filterService && $className !== $this->filterService) {
                    return null;
                }

                $methods = [];
                foreach ($node->getMethods() as $classMethod) {
                    $methodInfo = $this->extractMethod($classMethod);
                    if ($methodInfo !== null) {
                        $methods[] = $methodInfo;
                    }
                }

                if (!empty($methods)) {
                    $this->services[] = new ServiceInfo($className, $methods);
                }
                return null;
            }

            private ?string $docComment = null;

            private function extractMethod(Node\Stmt\ClassMethod $node): ?MethodInfo
            {
                $docComment = $node->getDocComment();
                $docText = $docComment ? $docComment->getText() : '';

                // @yar-skip → 排除
                if (preg_match('/@yar-skip/', $docText)) {
                    return null;
                }
                // 无 @yar-rpc → Mode 1 下不生成
                if (!preg_match('/@yar-rpc/', $docText)) {
                    return null;
                }

                // 提取参数
                $params = [];
                $paramIndex = 1;
                $phpDocParams = $this->parsePhpDocParams($docText);

                foreach ($node->params as $param) {
                    $name = $param->var->name;
                    $type = $this->resolveType($param, $phpDocParams[$name] ?? null);
                    $params[] = new ParamInfo($name, $type, $paramIndex++);
                }

                // 提取返回类型
                $returnType = $this->resolveReturnType($node, $docText);

                return new MethodInfo(
                    $node->name->name,
                    $params,
                    $returnType
                );
            }

            private function resolveType(Node\Param $param, ?string $docType): string
            {
                // 优先级: PHP 类型提示 → PHPDoc → 默认值推断 → string 回退
                if ($param->type) {
                    $typeName = $param->type instanceof Node\Name
                        ? $param->type->toString()
                        : (string)$param->type;
                    return $this->typeMapper->map($typeName);
                }
                if ($docType) {
                    return $this->typeMapper->map($docType);
                }
                if ($param->default) {
                    $inferred = $this->typeMapper->inferFromDefault($param->default);
                    if ($inferred) return $inferred;
                }
                return 'string'; // 保守回退
            }

            private function resolveReturnType(Node\Stmt\ClassMethod $node, string $docText): string
            {
                // PHPDoc @return 优先
                if (preg_match('/@return\s+(\S+)/', $docText, $m)) {
                    return $this->typeMapper->mapReturnType($m[1]);
                }
                // PHP 类型提示
                if ($node->returnType) {
                    $typeName = $node->returnType instanceof Node\Name
                        ? $node->returnType->toString()
                        : (string)$node->returnType;
                    return $this->typeMapper->mapReturnType($typeName);
                }
                return 'google.protobuf.Empty';
            }

            private function parsePhpDocParams(string $doc): array
            {
                $params = [];
                if (preg_match_all('/@param\s+(\S+)\s+\$(\w+)/', $doc, $m, PREG_SET_ORDER)) {
                    foreach ($m as $match) {
                        $params[$match[2]] = $match[1];
                    }
                }
                return $params;
            }

            public function getServices(): array { return $this->services; }
        };

        $traverser->addVisitor($visitor);
        $traverser->traverse($ast);

        return $visitor->getServices();
    }

    private function findPhpFiles(string $dir): array
    {
        $iterator = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($dir, \FilesystemIterator::SKIP_DOTS)
        );
        $files = [];
        foreach ($iterator as $file) {
            if ($file->getExtension() === 'php') {
                $files[] = $file->getPathname();
            }
        }
        return $files;
    }
}
```

### src/TypeMapper.php — PHP 类型 → Protobuf 类型映射

```php
<?php
namespace Yar\ProtoGenerator;

use PhpParser\Node;

class TypeMapper
{
    /** PHP 标量类型 → Protobuf 类型 */
    private const SCALAR_MAP = [
        'int'     => 'int32',
        'integer' => 'int32',
        'float'   => 'double',
        'double'  => 'double',
        'string'  => 'string',
        'bool'    => 'bool',
        'boolean' => 'bool',
        'true'    => 'bool',
        'false'   => 'bool',
        'null'    => 'google.protobuf.Empty',
        'void'    => 'google.protobuf.Empty',
    ];

    public function map(string $phpType): string
    {
        $phpType = trim($phpType, '\\');
        return self::SCALAR_MAP[strtolower($phpType)] ?? 'string';
    }

    /**
     * 解析 @return 类型注解，支持复杂类型
     * - array{name: string, age: int} → 关联数组 message
     * - array<int, Foo> → repeated Foo
     * - int → 标量
     */
    public function mapReturnType(string $docType): string
    {
        $docType = trim($docType);

        // void / null
        if (in_array(strtolower($docType), ['void', 'null'], true)) {
            return 'google.protobuf.Empty';
        }

        // 标量
        if (isset(self::SCALAR_MAP[strtolower($docType)])) {
            return self::SCALAR_MAP[strtolower($docType)];
        }

        // array{key: type, ...} → 关联数组 (生成嵌套 message)
        if (preg_match('/^array\{(.+)\}$/s', $docType, $m)) {
            return 'assoc_array'; // 标记，由 ProtoGenerator 处理
        }

        // array<int, ItemType> → repeated
        if (preg_match('/^array<int,\s*(.+)>$/', $docType, $m)) {
            return 'repeated:' . $this->mapReturnType($m[1]);
        }

        // array → 回退 string (JSON)
        if (strtolower($docType) === 'array') {
            return 'string';
        }

        // 自定义类 → message
        return $docType;
    }

    /**
     * 从默认值推断类型
     */
    public function inferFromDefault(Node\Expr $default): ?string
    {
        if ($default instanceof Node\Scalar\LNumber)  return 'int32';
        if ($default instanceof Node\Scalar\DNumber)  return 'double';
        if ($default instanceof Node\Scalar\String_)  return 'string';
        if ($default instanceof Node\Expr\ConstFetch) {
            $name = $default->name->toString();
            if (in_array(strtolower($name), ['true', 'false'], true)) return 'bool';
            if (strtolower($name) === 'null') return 'google.protobuf.Empty';
        }
        return null;
    }
}
```

### src/Generator/ProtoGenerator.php — .proto 文本生成

```php
<?php
namespace Yar\ProtoGenerator\Generator;

use Yar\ProtoGenerator\Model\{ServiceInfo, MethodInfo, ParamInfo};

class ProtoGenerator
{
    public function generate(array $services): string
    {
        $lines = ['syntax = "proto3";', ''];

        $needsEmpty = false;

        foreach ($services as $service) {
            $lines = array_merge($lines, $this->generateService($service, $needsEmpty));
            $lines[] = '';
        }

        // 按需添加 import
        $header = [];
        if ($needsEmpty) {
            $header[] = 'import "google/protobuf/empty.proto";';
            $header[] = '';
        }

        return implode("\n", array_merge($header, $lines)) . "\n";
    }

    private function generateService(ServiceInfo $service, bool &$needsEmpty): array
    {
        $svcName = $service->name;
        $lines = ["// --- {$svcName} 服务 ---"];
        $rpcLines = [];

        foreach ($service->methods as $method) {
            $reqName = "{$svcName}_{$this->toPascal($method->name)}Request";
            $respName = "{$svcName}_{$this->toPascal($method->name)}Response";

            // Request message
            $lines = array_merge($lines, $this->generateRequestMessage($reqName, $method->params));

            // Response message
            $lines = array_merge($lines, $this->generateResponseMessage($respName, $method->returnType, $needsEmpty));

            // RPC 声明
            $rpcName = $this->toPascal($method->name);
            $retType = ($method->returnType === 'google.protobuf.Empty')
                ? 'google.protobuf.Empty'
                : $respName;
            $rpcLines[] = sprintf('    rpc %s(%s) returns (%s);', $rpcName, $reqName, $retType);
        }

        // Service 声明
        $lines[] = "service {$svcName} {";
        $lines = array_merge($lines, $rpcLines);
        $lines[] = '}';

        return $lines;
    }

    private function generateRequestMessage(string $name, array $params): array
    {
        $lines = ["message {$name} {"];
        foreach ($params as $param) {
            /** @var ParamInfo $param */
            $lines[] = sprintf('    %s %s = %d;  // 参数 $%s',
                $param->protoType, $param->name, $param->fieldNumber, $param->name
            );
        }
        $lines[] = '}';
        return $lines;
    }

    private function generateResponseMessage(string $name, string $returnType, bool &$needsEmpty): array
    {
        // void → Empty
        if ($returnType === 'google.protobuf.Empty') {
            $needsEmpty = true;
            return []; // 无 Response message，用 google.protobuf.Empty
        }

        // 标量 → { result = 1; }
        if (in_array($returnType, ['int32', 'int64', 'double', 'string', 'bool'])) {
            return ["message {$name} {", "    {$returnType} result = 1;", '}'];
        }

        // 关联数组 → 逐字段生成
        if ($returnType === 'assoc_array') {
            // 简化示例：实际应解析 array{...} 的 key-value
            return ["message {$name} {", '    // TODO: 解析 @return array{...} 字段', '}'];
        }

        // repeated → { repeated ItemType items = 1; }
        if (str_starts_with($returnType, 'repeated:')) {
            $itemType = substr($returnType, strlen('repeated:'));
            return ["message {$name} {", "    repeated {$itemType} items = 1;", '}'];
        }

        // 自定义 message
        return ["message {$name} {", "    {$returnType} result = 1;", '}'];
    }

    private function toPascal(string $name): string
    {
        return ucfirst($name);
    }
}
```

### src/Compiler/ProtocCompiler.php — .pb 编译

```php
<?php
namespace Yar\ProtoGenerator\Compiler;

use Symfony\Component\Process\Process;

class ProtocCompiler implements PbCompilerInterface
{
    private string $protocPath;

    public function __construct(?string $protocPath = null)
    {
        $this->protocPath = $protocPath ?? $this->findProtoc();
    }

    public function compile(string $protoText, string $outputPath, bool $keepProto = false): void
    {
        $tmpDir = sys_get_temp_dir() . '/yar2proto_' . uniqid();
        @mkdir($tmpDir, 0755, true);

        try {
            $protoFile = $tmpDir . '/service.proto';
            file_put_contents($protoFile, $protoText);

            // protoc --descriptor_set_out=output.pb --include_imports input.proto
            $cmd = [
                $this->protocPath,
                '--descriptor_set_out=' . $outputPath,
                '--include_imports',
                $protoFile,
            ];

            $process = new Process($cmd);
            $process->mustRun();

            if ($keepProto) {
                $protoOutput = preg_replace('/\.pb$/', '.proto', $outputPath);
                copy($protoFile, $protoOutput);
            }
        } finally {
            $this->cleanup($tmpDir);
        }
    }

    private function findProtoc(): string
    {
        $paths = ['/usr/local/bin/protoc', '/usr/bin/protoc'];
        foreach ($paths as $path) {
            if (is_executable($path)) return $path;
        }
        // 尝试从 PATH 查找
        exec('which protoc', $output, $code);
        if ($code === 0 && !empty($output[0])) {
            return $output[0];
        }
        throw new \RuntimeException('protoc not found. Install it or specify --protoc=/path/to/protoc');
    }

    private function cleanup(string $dir): void
    {
        if (!is_dir($dir)) return;
        foreach (glob($dir . '/*') as $file) @unlink($file);
        @rmdir($dir);
    }
}
```

### src/Model — 数据模型

```php
<?php
namespace Yar\ProtoGenerator\Model;

class ServiceInfo
{
    public function __construct(
        public string $name,
        public array $methods  // MethodInfo[]
    ) {}
}

class MethodInfo
{
    public function __construct(
        public string $name,
        public array $params,     // ParamInfo[]
        public string $returnType // Protobuf 类型字符串
    ) {}
}

class ParamInfo
{
    public function __construct(
        public string $name,
        public string $protoType,
        public int $fieldNumber
    ) {}
}
```

### 形态 A 完整流程图

```
┌──────────────────────────────────────────────────────────────────┐
│              形态 A: 纯 PHP CLI 工具完整流程                        │
│                                                                  │
│  $ yar2proto generate src/Calculator.php \                       │
│      --output=proto/calc.pb --keep-proto                         │
│                                                                  │
│  ┌──────────┐    ┌──────────────┐    ┌──────────┐    ┌────────┐ │
│  │ CLI 入口  │───▶│ 分析器选择    │───▶│ .proto   │───▶│ .pb    │ │
│  │          │    │              │    │ 生成器   │    │ 编译器 │ │
│  │ Generate │    │ Mode 1?      │    │          │    │        │ │
│  │ Command  │    │  PHP-Parser  │    │ ProtoGen │    │ protoc │ │
│  │          │    │ Mode 2?      │    │          │    │ 子进程  │ │
│  │ 解析参数  │    │  HTTP 内省   │    │ TypeMap  │    │        │ │
│  │          │    │ Hybrid?      │    │          │    │        │ │
│  │          │    │  两者结合    │    │          │    │        │ │
│  └──────────┘    └──────┬───────┘    └────┬─────┘    └───┬────┘ │
│                         │                 │              │      │
│                         ▼                 │              │      │
│  ┌──────────────────────────────────┐     │              │      │
│  │ PhpParserAnalyzer                │     │              │      │
│  │                                  │     │              │      │
│  │ 1. file_get_contents             │     │              │      │
│  │ 2. ParserFactory→parse → AST     │     │              │      │
│  │ 3. NodeTraverser 遍历            │     │              │      │
│  │    - Class_ → 类名               │     │              │      │
│  │    - ClassMethod → 方法名        │     │              │      │
│  │    - Param → 参数名/类型/默认值  │     │              │      │
│  │    - DocComment → @yar-rpc/skip  │     │              │      │
│  │    - @param/@return → PHPDoc类型 │     │              │      │
│  │ 4. TypeMapper 映射 PHP→Proto类型 │     │              │      │
│  │ 5. 返回 ServiceInfo[]            │─────┘              │      │
│  └──────────────────────────────────┘                    │      │
│                                                          │      │
│  ┌──────────────────────────────────────────────────┐    │      │
│  │ ProtoGenerator                                    │    │      │
│  │                                                   │    │      │
│  │ 输入: ServiceInfo[] (类名+方法列表+参数+返回类型) │────┘      │
│  │ 输出: .proto 文本                                 │           │
│  │                                                   │           │
│  │ - 生成 syntax/import 头                           │           │
│  │ - 每个方法生成 Request message                    │           │
│  │   field number = 参数顺序 (1-based)               │           │
│  │ - 每个方法生成 Response message                   │           │
│  │   标量→{result=1}, 关联数组→逐字段, repeated→items│           │
│  │ - 生成 service { rpc ... } 声明                  │           │
│  └──────────────────────────────────────────────────┘           │
│                                                                 │
│  ┌──────────────────────────────────────────────────┐           │
│  │ ProtocCompiler                                    │◀──────────┘
│  │                                                   │
│  │ 1. 写 .proto 到临时文件                            │
│  │ 2. 调用 protoc --descriptor_set_out=output.pb     │
│  │                       --include_imports            │
│  │ 3. --keep-proto 时复制 .proto 到输出目录           │
│  │ 4. 清理临时文件                                    │
│  └──────────────────────────────────────────────────┘           │
│                                                                 │
│  最终输出: proto/calc.pb (二进制描述符)                          │
│           proto/calc.proto (文本，--keep-proto 时)               │
└──────────────────────────────────────────────────────────────────┘
```

---

## 形态 B: PHP 扩展实现 (PECL)

### 扩展定位与命名

```
┌──────────────────────────────────────────────────────────────────┐
│              PHP 扩展 (PECL) 定位                                   │
│                                                                  │
│  扩展名: yar_proto_gen                                            │
│  PECL 包: yar_proto_gen                                           │
│  GitHub: github.com/yar-group/yar-proto-gen-ext                   │
│                                                                  │
│  定位:                                                            │
│  - C 扩展提供高性能 PHP 代码分析 + .proto 生成                    │
│  - PHP CLI 薄包装提供命令行接口 (复用形态 A 的 CLI 层)             │
│  - 扩展不直接调用 protoc，而是通过 PHP 层调用                       │
│    (或内联 libprotobuf 直接构造 .pb，避免 protoc 依赖)             │
│                                                                  │
│  与形态 A 的关系:                                                  │
│  - CLI 接口完全一致 (yar2proto generate ...)                      │
│  - 输出格式完全一致 (.proto / .pb)                                │
│  - 扩展替代 PHP-Parser 做 AST 分析 (更快)                         │
│  - 扩展可内联 protobuf-c 直接构造 .pb (无需 protoc)               │
│                                                                  │
│  分发:                                                            │
│  $ pecl install yar_proto_gen    # 安装 C 扩展                    │
│  $ composer global require yar/proto-gen  # 安装 CLI 包装          │
│  $ yar2proto generate ...        # 使用 (CLI 自动检测扩展是否加载) │
└──────────────────────────────────────────────────────────────────┘
```

### 扩展项目结构

```
yar-proto-gen-ext/
├── config.m4                    # Unix 构建配置
├── config.w32                   # Windows 构建配置
├── package.xml                  # PECL 包描述
├── php_yar_proto_gen.h          # 扩展头文件
├── yar_proto_gen.c              # 扩展入口 (MINIT/RINIT/MSHUTDOWN)
├── analyzer.c                    # PHP 代码分析核心 (Zend AST 解析)
├── type_mapper.c                 # PHP→Protobuf 类型映射
├── proto_generator.c            # .proto 文本生成
├── pb_builder.c                 # 编程构造 .pb (可选，用 protobuf-c)
├── introspection.c             # YAR Server HTTP 内省 (用 libcurl)
├── tests/                       # phpt 测试
│   ├── 001_analyze_class.phpt
│   ├── 002_type_mapping.phpt
│   ├── 003_generate_proto.phpt
│   └── ...
├── bin/
│   └── yar2proto                # CLI 入口 (PHP 脚本，调用扩展函数)
└── src/                         # PHP CLI 包装层
    ├── Application.php
    ├── Command/GenerateCommand.php
    └── Compiler/ProtocCompiler.php
```

### config.m4 — 构建配置

```m4
PHP_ARG_ENABLE(yar_proto_gen, whether to enable yar_proto_gen support,
[  --enable-yar_proto_gen      Enable yar_proto_gen support])

if test "$PHP_YAR_PROTO_GEN" != "no"; then
  # 可选: 链接 libcurl 用于 Mode 2 HTTP 内省
  PHP_CHECK_LIBRARY(curl, curl_easy_init, [
    PHP_ADD_LIBRARY(curl, YAR_PROTO_GEN_SHARED_LIBADD)
    AC_DEFINE(HAVE_CURL, 1, [Have libcurl])
  ], [
    AC_MSG_WARN([libcurl not found, Mode 2 introspection disabled])
  ], [])

  # 可选: 链接 protobuf-c 用于编程构造 .pb (无需 protoc)
  PHP_CHECK_LIBRARY(protobuf-c, protobuf_c_message_pack, [
    PHP_ADD_LIBRARY(protobuf-c, YAR_PROTO_GEN_SHARED_LIBADD)
    AC_DEFINE(HAVE_PROTOBUF_C, 1, [Have protobuf-c])
  ], [
    AC_MSG_WARN([protobuf-c not found, falling back to protoc subprocess])
  ], [])

  PHP_NEW_EXTENSION(yar_proto_gen,
    yar_proto_gen.c analyzer.c type_mapper.c proto_generator.c pb_builder.c introspection.c,
    $ext_shared)
fi
```

### yar_proto_gen.c — 扩展入口

```c
/* yar_proto_gen.c — PHP 扩展入口 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "php.h"
#include "ext/standard/info.h"
#include "php_yar_proto_gen.h"

/* 扩展函数注册 */
zend_function_entry yar_proto_gen_functions[] = {
    /* 核心: 分析 PHP 源码 → 返回 ServiceInfo 数组 */
    PHP_FE(yar_proto_analyze,        NULL)
    /* 生成 .proto 文本 */
    PHP_FE(yar_proto_generate,       NULL)
    /* 编程构造 .pb 二进制 (可选，需 protobuf-c) */
    PHP_FE(yar_proto_compile_pb,     NULL)
    /* HTTP 内省 (可选，需 libcurl) */
    PHP_FE(yar_proto_introspect,     NULL)
    PHP_FE_END
};

PHP_MINIT_FUNCTION(yar_proto_gen)
{
    /* 注册常量 */
    REGISTER_LONG_CONSTANT("YAR_PROTO_MODE_ANNOTATE",   1, CONST_CS | CONST_PERSISTENT);
    REGISTER_LONG_CONSTANT("YAR_PROTO_MODE_INTROSPECT", 2, CONST_CS | CONST_PERSISTENT);
    REGISTER_LONG_CONSTANT("YAR_PROTO_MODE_HYBRID",      3, CONST_CS | CONST_PERSISTENT);
    return SUCCESS;
}

PHP_MINFO_FUNCTION(yar_proto_gen)
{
    php_info_print_table_start();
    php_info_print_table_header(2, "yar_proto_gen", "enabled");
    php_info_print_table_row(2, "Version", "1.0.0");
#ifdef HAVE_CURL
    php_info_print_table_row(2, "Introspection (libcurl)", "enabled");
#else
    php_info_print_table_row(2, "Introspection (libcurl)", "disabled");
#endif
#ifdef HAVE_PROTOBUF_C
    php_info_print_table_row(2, "PB Builder (protobuf-c)", "enabled");
#else
    php_info_print_table_row(2, "PB Builder (protobuf-c)", "disabled (use protoc)");
#endif
    php_info_print_table_end();
}

zend_module_entry yar_proto_gen_module_entry = {
    STANDARD_MODULE_HEADER,
    "yar_proto_gen",
    yar_proto_gen_functions,
    PHP_MINIT(yar_proto_gen),
    NULL, /* RINIT */
    NULL, /* RSHUTDOWN */
    NULL, /* MSHUTDOWN */
    PHP_MINFO(yar_proto_gen),
    PHP_YAR_PROTO_GEN_VERSION,
    STANDARD_MODULE_PROPERTIES
};

ZEND_GET_MODULE(yar_proto_gen)

/* ──────────────────────────────────────────────────────────────────
 * yar_proto_analyze(string $source, int $mode, ?string $service): array
 *
 * 分析 PHP 源码，返回 ServiceInfo 结构:
 * [
 *   {
 *     "name": "Calculator",
 *     "methods": [
 *       {
 *         "name": "add",
 *         "params": [
 *           {"name": "a", "type": "int32", "number": 1},
 *           {"name": "b", "type": "int32", "number": 2}
 *         ],
 *         "return_type": "int32"
 *       },
 *       ...
 *     ]
 *   }
 * ]
 *
 * C 扩展内部使用 Zend AST 直接分析，无需 PHP-Parser。
 * PHP 7.0+ 的 Zend 引擎自带 AST，可通过 zend_compile_string /
 * zend_ast_process 等机制访问。
 * ────────────────────────────────────────────────────────────────── */
PHP_FUNCTION(yar_proto_analyze)
{
    char *source;
    size_t source_len;
    zend_long mode = 1;  /* 默认 Mode 1 */
    char *service_name = NULL;
    size_t service_len = 0;

    ZEND_PARSE_PARAMETERS_START(1, 3)
        Z_PARAM_PATH(source, source_len)
        Z_PARAM_OPTIONAL
        Z_PARAM_LONG(mode)
        Z_PARAM_PATH_OR_NULL(service_name, service_len)
    ZEND_PARSE_PARAMETERS_END();

    array_init(return_value);
    if (yar_proto_analyze_impl(source, mode, service_name, return_value) != SUCCESS) {
        RETURN_FALSE;
    }
}

/* ──────────────────────────────────────────────────────────────────
 * yar_proto_generate(array $services): string
 *
 * 接收 ServiceInfo 数组，生成 .proto 文本
 * ────────────────────────────────────────────────────────────────── */
PHP_FUNCTION(yar_proto_generate)
{
    zval *services;
    ZEND_PARSE_PARAMETERS_START(1, 1);
        Z_PARAM_ARRAY(services)
    ZEND_PARSE_PARAMETERS_END();

    char *proto_text = yar_proto_generate_impl(services);
    if (proto_text == NULL) {
        RETURN_EMPTY_STRING();
    }
    RETVAL_STRING(proto_text);
    efree(proto_text);
}

/* ──────────────────────────────────────────────────────────────────
 * yar_proto_compile_pb(string $proto_text, string $output_path): bool
 *
 * 编程构造 .pb (需 protobuf-c)，无需 protoc
 * 无 protobuf-c 时返回 false，PHP 层回退到 protoc 子进程
 * ────────────────────────────────────────────────────────────────── */
PHP_FUNCTION(yar_proto_compile_pb)
{
    char *proto_text;
    size_t text_len;
    char *output_path;
    size_t path_len;

    ZEND_PARSE_PARAMETERS_START(2, 2);
        Z_PARAM_STRING(proto_text, text_len)
        Z_PARAM_PATH(output_path, path_len)
    ZEND_PARSE_PARAMETERS_END();

#ifdef HAVE_PROTOBUF_C
    if (yar_proto_compile_pb_impl(proto_text, output_path) == SUCCESS) {
        RETURN_TRUE;
    }
#endif
    RETURN_FALSE;
}

/* ──────────────────────────────────────────────────────────────────
 * yar_proto_introspect(string $url, string $format): array
 *
 * HTTP GET YAR Server，解析方法列表 (需 libcurl)
 * ────────────────────────────────────────────────────────────────── */
PHP_FUNCTION(yar_proto_introspect)
{
    char *url;
    size_t url_len;
    char *format = "html";
    size_t fmt_len = 4;

    ZEND_PARSE_PARAMETERS_START(1, 2);
        Z_PARAM_PATH(url, url_len)
        Z_PARAM_OPTIONAL
        Z_PARAM_STRING(format, fmt_len)
    ZEND_PARSE_PARAMETERS_END();

#ifdef HAVE_CURL
    array_init(return_value);
    if (yar_proto_introspect_impl(url, format, return_value) != SUCCESS) {
        RETURN_FALSE;
    }
#else
    php_error(E_WARNING, "yar_proto_introspect requires libcurl");
    RETURN_FALSE;
#endif
}
```

### analyzer.c — 核心分析逻辑 (C 扩展)

```c
/* analyzer.c — PHP 源码分析核心
 *
 * 使用 Zend 引擎内置 AST 进行分析，无需 nikic/PHP-Parser。
 * PHP 7.0+ 的 zend_compile_string() 可将 PHP 源码编译为 AST，
 * 通过自定义 zend_ast_process 回调截获 AST 进行遍历。
 *
 * 优势:
 * - 无外部依赖 (不需要 Composer 包)
 * - 性能极高 (C 层 AST 遍历，无 PHP 层开销)
 * - 支持 PHP 7.0-8.4 (Zend AST 从 PHP 7.0 开始稳定)
 *
 * 分析流程:
 * 1. 读取 PHP 源码文件
 * 2. zend_compile_string() → 获取 AST
 * 3. 遍历 AST 节点:
 *    - ZEND_AST_CLASS → 类名
 *    - ZEND_AST_METHOD → 方法名、参数、返回类型
 *    - ZEND_AST_PARAM → 参数名、类型提示、默认值
 * 4. 解析 DocComment (通过 AST 的 doc_comment 属性)
 * 5. @yar-rpc 筛选 / @yar-skip 排除
 * 6. 类型映射 (type_mapper.c)
 * 7. 返回 ServiceInfo 结构
 */

#include "php_yar_proto_gen.h"
#include "zend_ast.h"
#include "zend_language_scanner.h"
#include "zend_language_parser.h"

/* 全局上下文，用于 AST 遍历回调 */
typedef struct {
    HashTable *services;     /* 输出: 服务列表 */
    const char *filter_svc;  /* 过滤的服务名 */
    int mode;                /* 分析模式 */
} analyze_ctx_t;

static analyze_ctx_t g_ctx;

/* AST 遍历回调 */
static void analyze_ast_node(zend_ast *ast, analyze_ctx_t *ctx);

/* 主入口: 分析 PHP 源码文件 */
int yar_proto_analyze_impl(const char *source, int mode,
                           const char *filter_svc, zval *return_value)
{
    g_ctx.services = emalloc(sizeof(HashTable));
    zend_hash_init(g_ctx.services, 8, NULL, ZVAL_PTR_DTOR, 0);
    g_ctx.filter_svc = filter_svc;
    g_ctx.mode = mode;

    /* 1. 读取源码 */
    char *code;
    size_t code_len;
    if (read_source_file(source, &code, &code_len) != SUCCESS) {
        efree(g_ctx.services);
        return FAILURE;
    }

    /* 2. 编译为 AST (不执行)
     *    利用 Zend 引擎的编译流程，截获 AST 而不执行 opcode
     */
    zend_string *source_string = zend_string_init(code, code_len, 0);

    zend_lex_state lex_state;
    zend_save_lexical_state(&lex_state);

    if (zend_prepare_string_for_scanning(source_string, source) == SUCCESS) {
        CG(ast_arena) = zend_arena_create(1024 * 1024);

        zend_ast *ast;
        if (zendparse() == SUCCESS) {
            /* 遍历 AST */
            analyze_ast_node(ast, &g_ctx);
        }

        zend_arena_destroy(CG(ast_arena));
    }

    zend_restore_lexical_state(&lex_state);

    /* 3. 将结果填入 return_value */
    zval services_zv;
    array_init(&services_zv);

    zval *val;
    ZEND_HASH_FOREACH_VAL(g_ctx.services, val) {
        add_next_index_zval(&services_zv, val);
        Z_TRY_ADDREF_P(val);
    } ZEND_HASH_FOREACH_END();

    ZVAL_COPY_VALUE(return_value, &services_zv);

    zend_hash_destroy(g_ctx.services);
    efree(g_ctx.services);
    efree(code);
    zend_string_release(source_string);

    return SUCCESS;
}

/* AST 节点遍历 */
static void analyze_ast_node(zend_ast *ast, analyze_ctx_t *ctx)
{
    if (ast == NULL) return;

    /* 处理类声明 */
    if (ast->kind == ZEND_AST_CLASS) {
        zend_ast_decl *class_decl = (zend_ast_decl *)ast;
        const char *class_name = ZSTR_VAL(class_decl->name);

        /* 过滤服务名 */
        if (ctx->filter_svc && strcmp(class_name, ctx->filter_svc) != 0) {
            return;
        }

        /* 遍历类体中的方法 */
        zend_ast *class_body = class_decl->child[0];
        if (class_body && class_body->kind == ZEND_AST_STMT_LIST) {
            zend_ast_list *list = (zend_ast_list *)class_body;
            for (int i = 0; i < list->children; i++) {
                zend_ast *stmt = list->child[i];
                if (stmt->kind == ZEND_AST_METHOD) {
                    analyze_method(stmt, class_name, ctx);
                }
            }
        }
    }

    /* 递归遍历子节点 */
    if (ast->kind >> ZEND_AST_TYPE_SHIFT == ZEND_AST_TYPE_LIST) {
        zend_ast_list *list = (zend_ast_list *)ast;
        for (int i = 0; i < list->children; i++) {
            analyze_ast_node(list->child[i], ctx);
        }
    } else {
        for (int i = 0; i < ast->children; i++) {
            analyze_ast_node(ast->child[i], ctx);
        }
    }
}

/* 分析方法节点 */
static void analyze_method(zend_ast *method_ast, const char *class_name,
                           analyze_ctx_t *ctx)
{
    zend_ast_decl *method_decl = (zend_ast_decl *)method_ast;
    const char *method_name = ZSTR_VAL(method_decl->name);

    /* 获取 DocComment */
    zend_string *doc_comment = method_decl->doc_comment;
    const char *doc_text = doc_comment ? ZSTR_VAL(doc_comment) : "";

    /* @yar-skip → 排除 */
    if (strstr(doc_text, "@yar-skip") != NULL) return;

    /* Mode 1: 需要 @yar-rpc 注解 */
    if (ctx->mode == 1 && strstr(doc_text, "@yar-rpc") == NULL) return;

    /* 提取参数 */
    zval params_arr;
    array_init(&params_arr);
    int param_number = 1;

    /* 方法参数列表 (method_decl->child[1] 是参数列表) */
    zend_ast *params_ast = method_decl->child[1];
    if (params_ast && params_ast->kind == ZEND_AST_PARAM_LIST) {
        zend_ast_list *params_list = (zend_ast_list *)params_ast;
        for (int i = 0; i < params_list->children; i++) {
            zend_ast *param_ast = params_list->child[i];
            if (param_ast->kind == ZEND_AST_PARAM) {
                analyze_param(param_ast, &params_arr, param_number++, doc_text);
            }
        }
    }

    /* 提取返回类型 */
    const char *return_type = "google.protobuf.Empty";
    if (method_decl->child[2] != NULL) {
        /* 有返回类型提示 */
        return_type = map_return_type_from_ast(method_decl->child[2], doc_text);
    } else {
        /* 从 PHPDoc 解析 */
        return_type = map_return_type_from_doc(doc_text);
    }

    /* 构造方法信息并加入服务 */
    zval method_info;
    array_init(&method_info);
    add_assoc_string(&method_info, "name", method_name);
    add_assoc_zval(&method_info, "params", &params_arr);
    add_assoc_string(&method_info, "return_type", return_type);

    add_service_method(ctx->services, class_name, &method_info);
}

/* 分析参数节点 */
static void analyze_param(zend_ast *param_ast, zval *params_arr,
                          int number, const char *doc_text)
{
    zend_ast_decl *param_decl = (zend_ast_decl *)param_ast;
    const char *param_name = ZSTR_VAL(param_decl->name);

    /* 类型提示 (param_decl->child[0] 是类型) */
    const char *proto_type = "string"; /* 保守回退 */
    if (param_decl->child[0] != NULL) {
        proto_type = map_type_from_ast(param_decl->child[0]);
    } else {
        /* 从 PHPDoc 解析 @param */
        proto_type = map_type_from_doc(doc_text, param_name);
    }

    /* 默认值推断 (param_decl->child[1] 是默认值表达式) */
    if (param_decl->child[1] != NULL && strcmp(proto_type, "string") == 0) {
        proto_type = infer_type_from_default_ast(param_decl->child[1]);
    }

    zval param_info;
    array_init(&param_info);
    add_assoc_string(&param_info, "name", param_name);
    add_assoc_string(&param_info, "type", proto_type);
    add_assoc_long(&param_info, "number", number);
    add_next_index_zval(params_arr, &param_info);
}

/* 读取源码文件 */
static int read_source_file(const char *path, char **code, size_t *code_len)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) return FAILURE;

    fseek(fp, 0, SEEK_END);
    *code_len = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    *code = emalloc(*code_len + 1);
    fread(*code, 1, *code_len, fp);
    (*code)[*code_len] = '\0';
    fclose(fp);

    return SUCCESS;
}
```

### PHP CLI 包装层 (bin/yar2proto)

```php
#!/usr/bin/env php
<?php
/**
 * bin/yar2proto — CLI 入口 (扩展 + 纯 PHP 降级)
 *
 * 自动检测 yar_proto_gen 扩展是否加载:
 * - 已加载 → 使用 C 扩展的高性能分析
 * - 未加载 → 降级到纯 PHP (nikic/php-parser) 实现
 */

require __DIR__ . '/../vendor/autoload.php';

use Symfony\Component\Console\Application;
use Yar\ProtoGenerator\Command\GenerateCommand;

// 检测扩展
if (!function_exists('yar_proto_analyze')) {
    fwrite(STDERR,
        "Warning: yar_proto_gen extension not loaded. " .
        "Falling back to pure PHP (nikic/php-parser).\n" .
        "Install the extension for better performance:\n" .
        "  $ pecl install yar_proto_gen\n\n"
    );
}

$app = new Application('yar2proto', '1.0.0');
$app->add(new GenerateCommand());
$app->run();
```

### GenerateCommand.php — 扩展感知的命令

```php
<?php
namespace Yar\ProtoGenerator\Command;

use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\{InputInterface, InputOption, InputArgument};
use Symfony\Component\Console\Output\OutputInterface;

class GenerateCommand extends Command
{
    protected static $defaultName = 'generate';

    protected function configure(): void
    {
        $this->setDescription('Generate .proto/.pb from PHP YAR Server code')
            ->addArgument('source', InputArgument::OPTIONAL, 'PHP source file or directory')
            ->addOption('output', 'o', InputOption::VALUE_REQUIRED, 'Output .pb file path')
            ->addOption('keep-proto', null, InputOption::VALUE_NONE, 'Keep .proto text file')
            ->addOption('server', 's', InputOption::VALUE_OPTIONAL, 'YAR Server URL')
            ->addOption('service', null, InputOption::VALUE_OPTIONAL, 'Service name');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $source = $input->getArgument('source');
        $outputPath = $input->getOption('output');

        // 1. 分析 — 扩展优先，纯 PHP 降级
        $services = $this->analyze($source, $input);

        if (empty($services)) {
            $output->writeln('<error>No @yar-rpc methods found.</error>');
            return Command::FAILURE;
        }

        // 2. 生成 .proto 文本 — 扩展优先，纯 PHP 降级
        $protoText = $this->generateProto($services);

        // 3. 编译 .pb — 扩展内联优先，protoc 降级
        $this->compilePb($protoText, $outputPath, $input->getOption('keep-proto'));

        $output->writeln("<info>Generated: {$outputPath}</info>");
        return Command::SUCCESS;
    }

    private function analyze(string $source, InputInterface $input): array
    {
        $service = $input->getOption('service');

        // 扩展可用 → C 层高性能分析
        if (function_exists('yar_proto_analyze')) {
            $result = yar_proto_analyze(
                $source,
                YAR_PROTO_MODE_ANNOTATE,
                $service
            );
            return is_array($result) ? $result : [];
        }

        // 降级: 纯 PHP (nikic/php-parser)
        $analyzer = new \Yar\ProtoGenerator\Analyzer\PhpParserAnalyzer();
        return $analyzer->analyze($source, $service);
    }

    private function generateProto(array $services): string
    {
        // 扩展可用 → C 层生成
        if (function_exists('yar_proto_generate')) {
            return yar_proto_generate($services);
        }

        // 降级: 纯 PHP
        $generator = new \Yar\ProtoGenerator\Generator\ProtoGenerator();
        return $generator->generate($services);
    }

    private function compilePb(string $protoText, string $outputPath, bool $keepProto): void
    {
        // 扩展 + protobuf-c 可用 → 内联编译 (无需 protoc)
        if (function_exists('yar_proto_compile_pb')
            && yar_proto_compile_pb($protoText, $outputPath)) {
            if ($keepProto) {
                $protoFile = preg_replace('/\.pb$/', '.proto', $outputPath);
                file_put_contents($protoFile, $protoText);
            }
            return;
        }

        // 降级: protoc 子进程
        $compiler = new \Yar\ProtoGenerator\Compiler\ProtocCompiler();
        $compiler->compile($protoText, $outputPath, $keepProto);
    }
}
```

### 形态 B 扩展与 YAR 交互流程

```
┌──────────────────────────────────────────────────────────────────┐
│              形态 B: PHP 扩展与 YAR 交互流程                        │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                     用户终端                                  │ │
│  │                                                             │ │
│  │  $ yar2proto generate src/Calculator.php \                  │ │
│  │      --output=proto/calc.pb --keep-proto                    │ │
│  │                                                             │ │
│  │  $ yar2proto generate --server=http://127.0.0.1:8888/api \ │ │
│  │      --service=Calculator --output=proto/calc.pb           │ │
│  └───────────────────────┬─────────────────────────────────────┘ │
│                          │                                       │
│                          ▼                                       │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │              PHP CLI 层 (bin/yar2proto)                      │ │
│  │                                                             │ │
│  │  GenerateCommand::execute()                                 │ │
│  │  ┌─────────────────────────────────────────┐                │ │
│  │  │ 1. analyze(source)                      │                │ │
│  │  │    function_exists('yar_proto_analyze')? │                │ │
│  │  │    ├─ YES → C 扩展分析 (高性能)          │                │ │
│  │  │    └─ NO  → PHP-Parser 降级             │                │ │
│  │  ├─────────────────────────────────────────┤                │ │
│  │  │ 2. generateProto(services)               │                │ │
│  │  │    function_exists('yar_proto_generate')?│                │ │
│  │  │    ├─ YES → C 扩展生成 .proto           │                │ │
│  │  │    └─ NO  → PHP ProtoGenerator 降级     │                │ │
│  │  ├─────────────────────────────────────────┤                │ │
│  │  │ 3. compilePb(protoText, output)         │                │ │
│  │  │    function_exists('yar_proto_compile_pb')?│              │ │
│  │  │    ├─ YES + protobuf-c → 内联编译       │                │ │
│  │  │    └─ NO  → protoc 子进程降级           │                │ │
│  │  └─────────────────────────────────────────┘                │ │
│  └───────────────────────┬─────────────────────────────────────┘ │
│                          │                                       │
│          ┌───────────────┴───────────────┐                      │
│          ▼                               ▼                      │
│  ┌───────────────────┐          ┌──────────────────┐            │
│  │  C 扩展层          │          │  纯 PHP 降级层     │            │
│  │  (yar_proto_gen)  │          │  (Composer 包)     │            │
│  │                   │          │                    │            │
│  │ ┌───────────────┐ │          │ ┌────────────────┐ │            │
│  │ │ analyzer.c    │ │          │ │ PhpParser      │ │            │
│  │ │ Zend AST 遍历 │ │          │ │ Analyzer       │ │            │
│  │ │ @yar-rpc 筛选 │ │          │ │ nikic/php-parser│ │           │
│  │ │ 类型映射      │ │          │ └────────────────┘ │            │
│  │ └───────────────┘ │          │ ┌────────────────┐ │            │
│  │ ┌───────────────┐ │          │ │ ProtoGenerator │ │            │
│  │ │ proto_gen.c   │ │          │ │ .proto 文本生成 │ │            │
│  │ │ .proto 生成   │ │          │ └────────────────┘ │            │
│  │ └───────────────┘ │          │ ┌────────────────┐ │            │
│  │ ┌───────────────┐ │          │ │ ProtocCompiler │ │            │
│  │ │ pb_builder.c  │ │          │ │ protoc 子进程  │ │            │
│  │ │ protobuf-c    │ │          │ └────────────────┘ │            │
│  │ │ 内联 .pb 构造 │ │          │                    │            │
│  │ └───────────────┘ │          │                    │            │
│  │ ┌───────────────┐ │          │                    │            │
│  │ │ introspect.c  │ │          │                    │            │
│  │ │ libcurl HTTP  │ │          │                    │            │
│  │ │ YAR 内省      │ │          │                    │            │
│  │ └───────────────┘ │          │                    │            │
│  └───────┬───────────┘          └──────────────────┘            │
│          │ Mode 2: 内省                  │                      │
│          ▼                               │                      │
│  ┌──────────────────────────────────────────────────┐           │
│  │              YAR Server (PHP)                     │           │
│  │                                                  │           │
│  │  HTTP GET http://127.0.0.1:8888/api              │           │
│  │  ┌──────────────────────────────────────┐        │           │
│  │  │ YAR Server 内省响应                   │        │           │
│  │  │ - HTML 模式: 方法列表 + PHPDoc        │        │           │
│  │  │ - JSON 模式: 结构化方法列表 (__info)  │        │           │
│  │  └──────────────────────────────────────┘        │           │
│  │                                                  │           │
│  │  工具解析内省响应 → 方法列表 → 类型推断           │           │
│  │  (类型从源码 PHPDoc 补充，或回退 string)           │           │
│  └──────────────────────────────────────────────────┘           │
│                                                                  │
│  最终输出: proto/calc.pb + proto/calc.proto                      │
│           (C 扩展: 内联构造 .pb，无需 protoc)                     │
│           (纯 PHP: protoc 子进程编译 .pb)                         │
└──────────────────────────────────────────────────────────────────┘
```

### 扩展加载与运行时检测

```
┌──────────────────────────────────────────────────────────────────┐
│              扩展加载与运行时检测流程                                │
│                                                                  │
│  1. 安装扩展:                                                     │
│     $ pecl install yar_proto_gen                                 │
│     → 编译 .so/.dll，写入 php.ini: extension=yar_proto_gen.so    │
│                                                                  │
│  2. 安装 CLI:                                                     │
│     $ composer global require yar/proto-gen                      │
│     → 安装 bin/yar2proto + PHP 包装层                             │
│                                                                  │
│  3. 运行时检测:                                                   │
│     ┌──────────────────────────────────────────┐                │
│     │ bin/yar2proto 启动                        │                │
│     │                                          │                │
│     │ function_exists('yar_proto_analyze')?    │                │
│     │ ├─ true  → 扩展已加载，使用 C 层分析      │                │
│     │ └─ false → 扩展未加载，降级纯 PHP         │                │
│     │           → 输出 warning + 安装建议       │                │
│     └──────────────────────────────────────────┘                │
│                                                                  │
│  4. 三级降级策略:                                                 │
│     ┌────────────────┬──────────────┬─────────────┐             │
│     │ 最优            │ 中等         │ 降级         │             │
│     ├────────────────┼──────────────┼─────────────┤             │
│     │ C 扩展分析      │ PHP-Parser   │ PHP-Parser  │             │
│  │ C 扩展生成      │ PHP 生成     │ PHP 生成    │             │
│  │ protobuf-c 内联│ protoc 子进程│ protoc 子进程│             │
│  │                │              │              │             │
│  │ 无外部依赖      │ 需 protoc    │ 需 protoc   │             │
│  │ 最快           │ 中等         │ 较慢        │             │
│  └────────────────┴──────────────┴─────────────┘             │
│                                                                  │
│  5. php -m 确认扩展加载:                                          │
│     $ php -m | grep yar_proto_gen                                │
│     yar_proto_gen                                                 │
│                                                                  │
│  6. phpinfo() 查看能力:                                           │
│     yar_proto_gen  enabled                                        │
│     Introspection (libcurl)  enabled                              │
│     PB Builder (protobuf-c)  enabled                              │
└──────────────────────────────────────────────────────────────────┘
```

### 形态 A vs 形态 B 对比总结

```
┌──────────────────────────────────────────────────────────────────┐
│              形态 A vs 形态 B 对比总结                              │
│                                                                  │
│  维度        │ 形态 A (纯 PHP CLI)   │ 形态 B (PHP 扩展)          │
│  ────────────┼──────────────────────┼─────────────────────────── │
│  分析方式    │ nikic/PHP-Parser AST │ Zend 引擎内置 AST          │
│  生成方式    │ PHP ProtoGenerator   │ C proto_generator.c        │
│  .pb 编译    │ protoc 子进程 (必须)  │ protobuf-c 内联 (可选)     │
│  HTTP 内省   │ Guzzle HTTP Client   │ libcurl (C 层)             │
│  性能        │ 中等                  │ 高 (C 层，无 PHP 开销)     │
│  外部依赖    │ Composer + protoc    │ 无 (protobuf-c 可选)       │
│  安装复杂度  │ 低 (composer require)│ 中 (pecl install + 编译)  │
│  跨平台      │ 好 (纯 PHP)          │ 需各平台编译               │
│  维护成本    │ 低 (PHP 代码)        │ 高 (C 代码)                │
│  适用场景    │ 开发环境, CI/CD      │ 大型项目, 生产环境         │
│  推荐阶段    │ 1. 先实现 (验证设计)  │ 2. 性能瓶颈时迁移           │
│                                                                  │
│  共享部分 (两种形态完全一致):                                      │
│  - CLI 接口 (yar2proto generate ...)                             │
│  - 输出格式 (.proto 文本 + .pb 二进制)                            │
│  - 命名约定 ({Service}_{Method}Request/Response)                 │
│  - 类型映射规则 (PHP → Protobuf)                                 │
│  - 注解约定 (@yar-rpc / @yar-skip)                               │
│                                                                  │
│  推荐路线:                                                        │
│  1. 先用形态 A 实现并验证全部设计正确性                             │
│  2. 性能瓶颈出现时，将核心逻辑迁移到形态 B                         │
│  3. 两种形态可共存: 扩展未加载时自动降级到纯 PHP                   │
│  4. 用户无需关心底层实现，CLI 接口完全一致                         │
└──────────────────────────────────────────────────────────────────┘
```
