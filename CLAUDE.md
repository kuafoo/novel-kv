# NovelKV

专用小说章节文本 KV 存储系统，基于 Zig + RocksDB + Zstd 字典压缩。兼容 Redis 必要协议（RESP），可用 redis-cli 等标准客户端访问。

## 设计目标

以高压缩比存储全文本小说章节为核心场景，不是通用 KV 存储，也不是 Redis 替代品。只实现文本存储所需的 Redis 命令子集。

## Architecture

- `src/main.zig` — CLI 入口，参数解析，信号处理
- `src/server.zig` — TCP 服务，RESP 协议解析，连接管理
- `src/command.zig` — 命令分发与处理（仅文本存储必要命令）
- `src/storage.zig` — RocksDB 封装，Column Family 管理，RwLock 并发
- `src/resp.zig` — RESP 协议写入
- `src/log.zig` — 分级日志（debug/info/warn/error）
- `src/replication.zig` — 主从复制（应用层命令复制，Oplog 广播）
- `src/tls_adapter.zig` — TLS 适配器，桥接 tls.Connection 到 std.Io.Reader/Writer
- `crawl_novels.py` — 小说爬虫，为压缩基准测试提供真实文本数据
- `src/compress_bench.zig` — 压缩基准测试工具
- `src/http_server.zig` — HTTP 只读章节接口（签名 URL 验证 + 限流 + CORS）
- `src/config.zig` — Redis conf 风格配置文件解析器

## Design Decisions

- **专用文本存储，非缓存。** TTL/Key 过期不在设计范围内，EXPIRE/TTL 等命令未实现
- Zstd 字典压缩针对中文小说文本优化，压缩比远优于通用压缩
- 16 个数据库通过 RocksDB Column Family 实现（可按小说/分类组织）
- RwLock 并发：读共享锁，复合写排他锁
- RocksDB Checkpoint 实现秒级热备份（硬链接 SST 文件）
- AUTH 密码认证（`--requirepass`）
- 主从复制：`--replicaof <host> <port>` 启动副本模式，最终一致性
- TLS 加密：`--tls-cert/--tls-key` 启用 TLS 1.3，`--tls-replica` 副本 TLS 连接
- 危险命令（flushdb/flushall）可禁用
- HTTP 只读章节接口：`/chapter/{key}?sign=xxx&t=timestamp`，HMAC-SHA256 签名 URL 防遍历和未授权调用，令牌桶限流
- Redis conf 风格配置文件：`--config path` 加载，CLI 参数可覆盖配置文件值。限流、存储引擎参数等放在配置文件

## Supported Commands

仅实现文本存储必要命令：

| 类别 | 命令 |
|---|---|
| 读写 | GET, SET, DEL, MGET, MSET, EXISTS, SETNX, STRLEN |
| 数据库 | SELECT, DBSIZE, FLUSHDB, FLUSHALL |
| 备份 | SAVE, BGSAVE |
| 连接 | PING, ECHO, QUIT, AUTH, COMMAND, CONFIG, INFO |
| 复制 | REPLCONF, PSYNC |
| HTTP | GET /chapter/{key}?sign=xxx&t=timestamp (只读，签名验证) |

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
