# NovelKV

专用小说章节文本 KV 存储系统，基于 Zig + RocksDB + Zstd 字典压缩。兼容 Redis 必要协议（RESP），可用 redis-cli 等标准客户端访问。

## 设计目标

以高压缩比存储全文本小说章节为核心场景，不是通用 KV 存储，也不是 Redis 替代品。只实现文本存储所需的 Redis 命令子集。

## Architecture

- `src/main.zig` — CLI 入口，功能开关，信号处理
- `src/config.zig` — Redis conf 风格配置文件解析器
- `src/server.zig` — TCP 服务，RESP 协议解析，连接管理
- `src/command.zig` — 命令分发与处理（仅文本存储必要命令）
- `src/storage.zig` — RocksDB 封装，Column Family 管理，RwLock 并发
- `src/resp.zig` — RESP 协议写入
- `src/log.zig` — 分级日志（debug/info/warn/error）
- `src/replication.zig` — 主从复制（应用层命令复制，Oplog 广播）
- `src/http_server.zig` — HTTP 只读章节接口（签名 URL 验证 + 限流 + CORS）
- `src/tls_adapter.zig` — TLS 适配器，桥接 tls.Connection 到 std.Io.Reader/Writer

## Design Decisions

- **专用文本存储，非缓存。** TTL/Key 过期不在设计范围内，EXPIRE/TTL 等命令未实现
- Zstd 字典压缩针对中文小说文本优化，压缩比远优于通用压缩
- 16 个数据库通过 RocksDB Column Family 实现（可按小说/分类组织）
- RwLock 并发：读共享锁，复合写排他锁
- RocksDB Checkpoint 实现秒级热备份（硬链接 SST 文件）
- **CLI 管启动，配置文件管参数。** CLI 仅 7 个选项（config/host/port/data + 3 个 enable 开关），所有调优参数走配置文件
- **安全默认值。** flushdb/flushall 默认禁用，需 `--enable-dangerous` 显式启用
- HTTP 只读章节接口需 `--enable-http` 显式启用，HMAC-SHA256 签名 URL + 令牌桶限流
- TLS 加密需 `--enable-tls` 显式启用
- 主从复制：配置文件 `replicaof` 启动副本模式，最终一致性

## CLI

```
novelkv [OPTIONS]

Options:
  -c, --config <PATH>        配置文件（Redis conf 风格）
  -H, --host <HOST>          监听地址 (默认: 0.0.0.0)
  -p, --port <PORT>          监听端口 (默认: 6379)
  -d, --data <PATH>          数据目录 (默认: ./data)
  --enable-http              启用 HTTP 章节接口
  --enable-tls               启用 TLS 加密
  --enable-dangerous         启用危险命令 (flushdb, flushall)
  --help                     帮助
```

## Config File

Redis conf 风格，`#` 注释，`key value` 每行一个：

```
# Server
host 0.0.0.0
port 6379
data /var/lib/novelkv
log-level info
requirepass mysecret

# TLS
tls-cert /etc/novelkv/certs/server.pem
tls-key /etc/novelkv/certs/server-key.pem
tls-ca /etc/novelkv/certs/ca.pem
tls-replica no

# Replication
replicaof master-host 6379
masterauth master-password

# HTTP Chapter API
http-port 8080
http-secret mysecret
http-sign-ttl 3600
http-rate-burst 30
http-rate-refill 10

# Storage Engine (tuned for novel text)
write-buffer-size 64mb
block-size 128kb
compression-level 9
bloom-bits 10
# dict-size 256kb
# zstd-train-bytes 10000000
```

## Supported Commands

| 类别 | 命令 |
|---|---|
| 读写 | GET, SET, DEL, MGET, MSET, EXISTS, SETNX, STRLEN |
| Hash | HSET, HGET, HDEL, HLEN, HGETALL, HKEYS, HVALS, HEXISTS |
| 扫描 | SCAN (cursor + MATCH + COUNT), KEYS (glob) |
| 数据库 | SELECT, DBSIZE, FLUSHDB, FLUSHALL |
| 备份 | SAVE, BGSAVE |
| 连接 | PING, ECHO, QUIT, AUTH, COMMAND, CONFIG, INFO |
| 复制 | REPLCONF, PSYNC |
| HTTP | GET /v1/data/{key}?sign=xxx&t=timestamp (只读，签名验证) |

## Build & Test

```bash
zig build                    # Build
zig build test               # Unit tests
./zig-out/bin/novelkv --help # Usage
```

## Dependencies

- Zig 0.16.0
- RocksDB (static lib in deps/lib/)
- Zstd, Snappy (static libs in deps/lib/)
- ianic/tls.zig (local dep in deps/tls.zig/)
- libc, libstdc++, libpthread, libdl, librt
