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
- **HTTP 章节接口** — 只读 HTTP API，HMAC-SHA256 签名 URL 防遍历，令牌桶限流，前端可直接加载小说内容
- **配置文件** — Redis conf 风格配置文件，CLI 仅保留启动开关，安全默认值

## 支持命令

| 类别 | 命令 |
|---|---|
| 读写 | GET, SET, DEL, MGET, MSET, EXISTS, SETNX, STRLEN, APPEND, SETRANGE, GETSET |
| Hash | HSET, HGET, HDEL, HLEN, HGETALL, HKEYS, HVALS, HEXISTS |
| 扫描 | SCAN (cursor + MATCH + COUNT), KEYS (glob) |
| 计数 | INCR, INCRBY, DECR, DECRBY |
| 数据库 | SELECT, DBSIZE, FLUSHDB, FLUSHALL |
| 备份 | SAVE, BGSAVE |
| 连接 | PING, ECHO, QUIT, AUTH, COMMAND, CONFIG, INFO |
| 复制 | REPLCONF, PSYNC |
| HTTP | GET /chapter/{key}?sign=xxx&t=timestamp (只读，签名验证) |

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
# 最简启动（无配置文件，默认端口 6379）
./zig-out/bin/novelkv

# 使用配置文件
./zig-out/bin/novelkv --config /etc/novelkv/novelkv.conf

# 启用 HTTP 和 TLS
./zig-out/bin/novelkv --config /etc/novelkv/novelkv.conf --enable-http --enable-tls
```

### 连接

```bash
redis-cli -p 6379
redis-cli -p 6379 -a mysecret
```

## CLI 选项

CLI 仅保留启动开关，所有调优参数走配置文件：

```
  -c, --config <PATH>        加载配置文件
  -H, --host <HOST>          监听地址 (默认: 0.0.0.0)
  -p, --port <PORT>          监听端口 (默认: 6379)
  -d, --data <PATH>          数据目录 (默认: ./data)
  --enable-http              启用 HTTP 章节接口 (需配置 http-port/http-secret)
  --enable-tls               启用 TLS 加密 (需配置 tls-cert/tls-key)
  --enable-dangerous         启用危险命令 (flushdb, flushall，默认禁用)
  --help                     帮助
```

## 配置文件

Redis conf 风格，`#` 注释，`key value` 每行一个。

```
# === Server ===
host 0.0.0.0
port 6379
data /var/lib/novelkv
log-level info
requirepass mysecret
disable-commands flushdb,flushall

# === TLS ===
tls-cert /etc/novelkv/certs/server.pem
tls-key /etc/novelkv/certs/server-key.pem
tls-ca /etc/novelkv/certs/ca.pem
tls-replica no

# === Replication ===
# replicaof master-host 6379
# masterauth master-password

# === HTTP Chapter API ===
http-port 8080
http-secret mysecret
http-sign-ttl 3600
http-rate-burst 30
http-rate-refill 10

# === Storage Engine ===
write-buffer-size 64mb
block-size 128kb
compression-level 9
bloom-bits 10
```

## HTTP 章节接口

HTTP 只读接口供前端直接加载小说章节内容，无需中间层。采用 HMAC-SHA256 签名 URL 防止恶意遍历和未授权调用。需在配置文件设置 `http-port` 和 `http-secret`，并加 `--enable-http` 启动。

### URL 格式

```
GET /chapter/{chapterkey}?sign=xxx&t=123456789
```

- `chapterkey` — RocksDB 中的 key
- `sign` — HMAC-SHA256 签名（hex 编码，64 字符）
- `t` — Unix 时间戳（十进制），服务端校验不超过 TTL

### 签名算法

```
sign = hex(HMAC-SHA256(secret, chapterkey + t))
```

Python 生成示例：

```python
import hmac, hashlib, time

secret = b"mysecret"
key = "chapter1"
t = str(int(time.time()))
sign = hmac.new(secret, (key + t).encode(), hashlib.sha256).hexdigest()
url = f"/chapter/{key}?sign={sign}&t={t}"
```

### 安全机制

- **签名验证** — 无有效签名返回 403，密钥不暴露给前端
- **时间戳过期** — 超过 TTL 的签名失效（默认 3600 秒）
- **限流** — 每 IP 令牌桶限流（默认 30 burst，10 token/秒补充），超限返回 429
- **Key 校验** — 拒绝路径遍历（`..`）、路径分隔符（`/`）、控制字符
- **CORS** — 支持浏览器跨域预检请求

限流参数通过配置文件调整：`http-rate-burst`（桶容量）、`http-rate-refill`（每秒补充令牌数）。

### 响应码

| 状态码 | 含义 |
|---|---|
| 200 | 成功，返回章节内容（text/plain; charset=utf-8） |
| 400 | 非法 key |
| 403 | 签名缺失、无效或过期 |
| 404 | key 不存在 |
| 405 | 非 GET 请求 |
| 429 | 请求过于频繁 |

## 部署

下载 [Latest Release](https://github.com/kuafoo/novel-kv/releases/latest) 并安装：

```bash
tar xzf novelkv-v1.2.0-linux-x86_64.tar.gz
cd novelkv-v1.2.0-linux-x86_64
sudo ./install.sh
```

安装后编辑配置文件：

```bash
sudo vim /etc/novelkv/novelkv.conf
sudo systemctl start novelkv
sudo systemctl status novelkv
sudo journalctl -u novelkv -f
```

systemd 服务默认使用 `--config /etc/novelkv/novelkv.conf`，可在 `/etc/novelkv/novelkv.env` 中追加 CLI 覆盖参数。

### 副本部署

在副本机器上安装后，配置文件中设置：

```
replicaof 主节点IP 6379
masterauth 密码
```

### TLS 部署

```bash
sudo mkdir -p /etc/novelkv/certs
sudo cp server.pem server-key.pem ca.pem /etc/novelkv/certs/
sudo chown -R novelkv:novelkv /etc/novelkv/certs
sudo chmod 600 /etc/novelkv/certs/server-key.pem
```

配置文件中设置 TLS 证书路径，启动时加 `--enable-tls`。

## 测试

```bash
zig build test
```

## 技术架构

```
src/main.zig         — CLI 入口，功能开关，信号处理
src/config.zig       — Redis conf 风格配置文件解析器
src/server.zig       — TCP 服务，RESP 协议解析，连接管理
src/command.zig      — 命令分发与处理
src/storage.zig      — RocksDB 封装，Column Family，RwLock 并发
src/resp.zig         — RESP 协议写入
src/log.zig          — 分级日志
src/replication.zig  — 主从复制，Oplog 广播
src/tls_adapter.zig  — TLS 适配器
src/http_server.zig  — HTTP 只读章节接口（签名 URL + 限流 + CORS）
```

## License

MIT
