# NovelKV

专用小说章节文本 KV 存储系统，基于 Zig + RocksDB + Zstd 字典压缩。兼容 Redis 协议（RESP），可用 redis-cli 等标准客户端直接访问。

## 特性

- **RESP 兼容** — 支持 redis-cli 及所有 Redis 客户端库
- **高压缩比** — Zstd 字典压缩，针对中文小说文本优化，压缩比远优于通用压缩
- **16 个数据库** — 通过 RocksDB Column Family 实现，可按小说/分类组织
- **并发安全** — RwLock 并发控制，读共享锁，复合写排他锁
- **主从复制** — 应用层命令复制，Oplog 广播，最终一致性
- **TLS 加密** — TLS 1.3 支持，客户端与副本连接均可加密
- **密码认证** — AUTH 密码验证
- **热备份** — 基于 RocksDB Checkpoint，秒级硬链接备份

## 支持命令

| 类别 | 命令 |
|---|---|
| 读写 | GET, SET, DEL, MGET, MSET, EXISTS, SETNX, STRLEN, APPEND, SETRANGE, GETSET |
| 计数 | INCR, INCRBY, DECR, DECRBY |
| 数据库 | SELECT, DBSIZE, FLUSHDB, FLUSHALL |
| 备份 | SAVE, BGSAVE |
| 连接 | PING, ECHO, QUIT, AUTH, COMMAND, CONFIG, INFO |
| 复制 | REPLCONF, PSYNC |

## 快速开始

### 构建

依赖：Zig 0.16.0+, RocksDB, Zstd, Snappy

```bash
git clone https://github.com/kuafoo/novel-kv.git
cd novel-kv
zig build
```

### 运行

```bash
# 默认启动，监听 6379 端口
./zig-out/bin/novelkv

# 设置密码
./zig-out/bin/novelkv --requirepass mysecret

# 启用 TLS
./zig-out/bin/novelkv --tls-cert cert.pem --tls-key key.pem

# 副本模式
./zig-out/bin/novelkv --port 16380 --replicaof 127.0.0.1 16379 --masterauth mysecret
```

### 连接

```bash
redis-cli -p 6379
redis-cli -p 6379 -a mysecret
```

## 部署

下载 [Latest Release](https://github.com/kuafoo/novel-kv/releases/latest) 并安装：

```bash
tar xzf novelkv-1.0.0-linux-x86_64.tar.gz
cd novelkv-1.0.0-linux-x86_64
sudo ./install.sh
```

安装后编辑 `/etc/novelkv/novelkv.conf` 配置密码和选项：

```bash
sudo systemctl start novelkv
sudo systemctl status novelkv
sudo journalctl -u novelkv -f
```

### 副本部署

在副本机器上安装后，修改配置：

```
NOVELKV_OPTS="--host 0.0.0.0 --port 6379 --data /var/lib/novelkv --log-level info --replicaof 主节点IP 6379 --masterauth 密码"
```

### TLS 部署

```bash
sudo mkdir -p /etc/novelkv/certs
sudo cp server.pem server-key.pem ca.pem /etc/novelkv/certs/
sudo chown -R novelkv:novelkv /etc/novelkv/certs
sudo chmod 600 /etc/novelkv/certs/server-key.pem
```

在配置中添加 `--tls-cert /etc/novelkv/certs/server.pem --tls-key /etc/novelkv/certs/server-key.pem`。

## 全部选项

```
  -H, --host <HOST>          监听地址 (默认: 0.0.0.0)
  -p, --port <PORT>          监听端口 (默认: 6379)
  -d, --data <PATH>          数据目录 (默认: ./data)
  -l, --log-level <LEVEL>    日志级别: debug, info, warn, error (默认: info)
  --disable-dangerous        禁用危险命令 (flushdb, flushall)
  --disable-commands <LIST>  禁用指定命令 (逗号分隔)
  -a, --requirepass <PASS>   客户端认证密码
  --replicaof <HOST> <PORT>  主从复制 (副本模式)
  --masterauth <PASS>        主节点认证密码
  --tls-cert <PATH>          TLS 证书文件
  --tls-key <PATH>           TLS 私钥文件
  --tls-ca <PATH>            CA 证书 (客户端/副本验证)
  --tls-replica              副本使用 TLS 连接主节点
```

## 测试

```bash
zig build test
```

## 技术架构

```
src/main.zig         — CLI 入口，参数解析，信号处理
src/server.zig       — TCP 服务，RESP 协议解析，连接管理
src/command.zig      — 命令分发与处理
src/storage.zig      — RocksDB 封装，Column Family，RwLock 并发
src/resp.zig         — RESP 协议写入
src/log.zig          — 分级日志
src/replication.zig  — 主从复制，Oplog 广播
src/tls_adapter.zig  — TLS 适配器
```

## License

MIT
