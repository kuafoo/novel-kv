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

## 支持命令

| 类别 | 命令 |
|---|---|
| 读写 | GET, SET, DEL, MGET, MSET, EXISTS, SETNX, STRLEN, APPEND, SETRANGE, GETSET |
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
# 默认启动，监听 6379 端口
./zig-out/bin/novelkv

# 设置密码
./zig-out/bin/novelkv --requirepass mysecret

# 启用 TLS
./zig-out/bin/novelkv --tls-cert cert.pem --tls-key key.pem

# 副本模式
./zig-out/bin/novelkv --port 16380 --replicaof 127.0.0.1 16379 --masterauth mysecret

# 启用 HTTP 章节接口
./zig-out/bin/novelkv --http-port 8080 --http-secret mysecret
```

### 连接

```bash
redis-cli -p 6379
redis-cli -p 6379 -a mysecret
```

## HTTP 章节接口

HTTP 只读接口供前端直接加载小说章节内容，无需中间层。采用 HMAC-SHA256 签名 URL 防止恶意遍历和未授权调用。

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
- **限流** — 每 IP 令牌桶限流（30 token，10 token/秒补充），超限返回 429
- **Key 校验** — 拒绝路径遍历（`..`）、路径分隔符（`/`）、控制字符
- **CORS** — 支持浏览器跨域预检请求

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
  --http-port <PORT>         启用 HTTP 章节接口
  --http-secret <SECRET>     HMAC-SHA256 签名密钥 (与 --http-port 配合必需)
  --http-sign-ttl <SECONDS>  签名有效期 (默认: 3600)
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
src/http_server.zig  — HTTP 只读章节接口（签名 URL + 限流 + CORS）
```

## License

MIT
