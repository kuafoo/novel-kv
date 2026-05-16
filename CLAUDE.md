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
- `crawl_novels.py` — 小说爬虫，为压缩基准测试提供真实文本数据
- `src/compress_bench.zig` — 压缩基准测试工具

## Design Decisions

- **专用文本存储，非缓存。** TTL/Key 过期不在设计范围内，EXPIRE/TTL 等命令未实现
- Zstd 字典压缩针对中文小说文本优化，压缩比远优于通用压缩
- 16 个数据库通过 RocksDB Column Family 实现（可按小说/分类组织）
- RwLock 并发：读共享锁，复合写排他锁
- RocksDB Checkpoint 实现秒级热备份（硬链接 SST 文件）
- AUTH 密码认证（`--requirepass`）
- 主从复制：`--replicaof <host> <port>` 启动副本模式，最终一致性
- 危险命令（flushdb/flushall）可禁用

## Supported Commands

仅实现文本存储必要命令：

| 类别 | 命令 |
|---|---|
| 读写 | GET, SET, DEL, MGET, MSET, EXISTS, SETNX, STRLEN |
| 数据库 | SELECT, DBSIZE, FLUSHDB, FLUSHALL |
| 备份 | SAVE, BGSAVE |
| 连接 | PING, ECHO, QUIT, AUTH, COMMAND, CONFIG, INFO |
| 复制 | REPLCONF, PSYNC |

## Build & Test

```bash
zig build                    # Build
zig build test               # Unit tests
./zig-out/bin/novelkv --help # Usage
```

## Dependencies

- Zig 0.17.0-dev
- RocksDB (static lib in deps/lib/)
- Zstd, Snappy (static libs in deps/lib/)
- libc, libstdc++, libpthread, libdl, librt
