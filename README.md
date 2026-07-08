# NIOForwarder

> 一个基于 **SwiftNIO** 的高性能 TCP/UDP 流量转发服务器，用一份 JSON 配置即可同时转发多条规则，并自带无锁流量统计。

[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![SwiftNIO](https://img.shields.io/badge/Powered%20by-SwiftNIO-blue.svg)](https://github.com/apple/swift-nio)
[![Platform](https://img.shields.io/badge/Platform-macOS%2010.15%2B-lightgrey.svg)](https://developer.apple.com/macos)

---

## ✨ 为什么选它

| 特性 | 说明 |
|------|------|
| 🚀 **SwiftNIO 原生驱动** | 事件循环、零拷贝 ByteBuffer、自适应内存分配，转发路径完全异步非阻塞 |
| 🌐 **TCP + UDP 双栈** | 一份配置同时跑 TCP 长连接转发和 UDP 会话转发（含 UDP 会话老化超时） |
| 📊 **无锁流量统计** | 基于 `swift-atomics` 的原子计数器，不阻塞转发路径；自动周期性上报 + 退出时落盘 JSON |
| ⚙️ **JSON 配置，开箱即用** | 只需一个 `config.json`，无需写代码即可添加、删除、调整转发规则 |
| 🛡️ **优雅关闭** | 监听 `SIGINT`，先关闭统计任务，再关闭所有 Channel 与 EventLoopGroup，不丢会话 |
| 🪵 **结构化日志** | 基于 `swift-log`，支持 trace / debug / info / warning / error / critical 多级输出 |
| 🧩 **Clean Architecture** | TCP / UDP / Config / Statistics 分层清晰，接入新协议或新指标极易扩展 |

---

## 🚀 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/yourusername/NIOForwarder.git
cd NIOForwarder
```

### 2. 准备配置文件

```bash
cp config.example.json config.json
# 按需编辑 config.json
```

### 3. 编译并运行

```bash
swift build
swift run NIOForwarder --config config.json
```

也可以覆盖日志级别：

```bash
swift run NIOForwarder --config config.json --log-level debug
```

---

## 📁 配置示例

```json
{
  "logLevel": "info",
  "statistics": {
    "enabled": true,
    "intervalSeconds": 60,
    "logOnShutdown": true,
    "outputPath": "/tmp/nioforwarder-stats.json"
  },
  "rules": [
    {
      "name": "tcp-to-local-ssh",
      "protocol": "tcp",
      "bindHost": "0.0.0.0",
      "bindPort": 2222,
      "targetHost": "127.0.0.1",
      "targetPort": 22
    },
    {
      "name": "udp-to-dns",
      "protocol": "udp",
      "bindHost": "0.0.0.0",
      "bindPort": 5353,
      "targetHost": "8.8.8.8",
      "targetPort": 53,
      "udpSessionTimeoutSeconds": 60
    }
  ]
}
```

### 字段说明

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `logLevel` | string | 否 | 日志级别：`trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical` |
| `statistics.enabled` | bool | 否 | 是否启用流量统计，默认 `true` |
| `statistics.intervalSeconds` | int | 否 | 统计上报间隔，默认 `60` 秒 |
| `statistics.logOnShutdown` | bool | 否 | 退出时是否输出最终统计，默认 `true` |
| `statistics.outputPath` | string | 否 | 统计 JSON 落盘路径，不填则只输出日志 |
| `rules[].name` | string | 是 | 规则名称，用于日志与统计区分 |
| `rules[].protocol` | string | 是 | `tcp` 或 `udp` |
| `rules[].bindHost` / `bindPort` | string / int | 是 | 监听地址与端口 |
| `rules[].targetHost` / `targetPort` | string / int | 是 | 目标地址与端口 |
| `rules[].udpSessionTimeoutSeconds` | int | 否 | UDP 会话空闲超时，默认 `60` 秒 |

---

## 📈 流量统计输出示例

运行过程中，你会看到类似日志：

```
[periodic] Statistics: rule=tcp-to-local-ssh protocol=tcp sent=1.23MB received=456.78KB total_connections=42 active_connections=3
[periodic] Statistics: rule=udp-to-dns protocol=udp sent=12.50KB received=8.30KB total_sessions=120 active_sessions=2
```

退出时还会输出 `final` 快照，若配置了 `outputPath`，统计结果会以如下 JSON 格式写入：

```json
{
  "timestamp": "2026-07-08T17:00:00Z",
  "rules": [
    {
      "rule_name": "tcp-to-local-ssh",
      "protocol_type": "tcp",
      "bytes_sent": 1293948,
      "bytes_received": 467820,
      "total_connections_or_sessions": 42,
      "active_connections_or_sessions": 3
    }
  ]
}
```

---

## 🏗️ 项目结构

```
Sources/NIOForwarder
├── EntryPoint.swift          # @main 入口：参数解析、信号处理、生命周期
├── CLI.swift                 # 命令行参数与帮助信息
├── Config.swift              # JSON 配置模型
├── Forwarder.swift           # 全局调度：启动/停止所有规则与统计上报
├── TCP
│   ├── TCPForwarder.swift    # TCP 监听与目标连接建立
│   └── TCPRelayHandler.swift # 双向字节转发 Handler
├── UDP
│   ├── UDPForwarder.swift    # UDP 监听、会话管理、超时清理
│   └── UDPTypes.swift        # UDP 会话与回包 Handler
└── Statistics
    ├── TrafficStatistics.swift    # 规则级统计注册表
    ├── RuleStats.swift            # 基于原子操作的无锁计数器
    └── StatisticsReporter.swift   # 定时/退出统计输出与 JSON 落盘
```

---

## 🛠️ 技术亮点

- **无锁并发**：转发路径上的字节数与连接数统计全部使用 `swift-atomics` 的 `ManagedAtomic`，避免传统锁竞争。
- **事件循环安全**：UDP 会话字典只在其所属 Channel 的 EventLoop 上读写，彻底规避并发修改风险。
- **零分配转发**：直接 relay NIO 的 `ByteBuffer`，TCP 双 Handler 配对后双向 `writeAndFlush`。
- **Swift 6 兼容**：项目使用 `swift-tools-version:6.0`，类型安全与并发检查走在社区前沿。

---

## 🤝 欢迎贡献

NIOForwarder 是一个小而美的网络工具项目，非常适合：

- 学习 **SwiftNIO** 的 Channel、Pipeline、Bootstrap 与 EventLoop 模型
- 实践 **Swift 并发**、原子操作与无锁数据结构
- 扩展新协议（TLS、Socks5、HTTP CONNECT、QUIC…）
- 增加新指标（延迟分位、连接耗时、错误码统计…）

### 如何参与

1. **Fork** 本仓库
2. 创建你的 feature branch：`git checkout -b feature/amazing-feature`
3. 提交改动：`git commit -m 'Add amazing feature'`
4. 推送分支：`git push origin feature/amazing-feature`
5. 发起 **Pull Request**

任何 issue、PR、文档改进、性能优化都热烈欢迎！

---

## 📜 许可证

[MIT License](LICENSE)

---

> 如果你觉得这个项目有用，请给一颗 ⭐，也欢迎分享给同样热爱 Swift 与网络编程的朋友！
