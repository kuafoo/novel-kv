# NovelKV

专用小说章节文本 KV 存储系统，基于 Zig + RocksDB + Zstd 字典压缩。兼容 Redis 协议（RESP），可用 redis-cli 等标准客户端直接访问。

## 特性

- **RESP 兼容** — 支持 redis-cli 及所有 Redis 客户端库（redis-py ≥7、Jedis、Lettuce、ioredis 等）
- **高压缩比** — Zstd 字典压缩，针对中文小说文本优化，压缩比远优于通用压缩
- **16 个数据库** — 通过 RocksDB Column Family 实现，可按小说/分类组织
- **并发安全** — RwLock 并发控制，读共享锁，复合写排他锁
- **Hash 类型** — HSET/HGET/HDEL/HGETALL 等，DEL 自动清理字段，EXISTS/TYPE 识别 hash
- **主从复制** — 应用层命令复制，Oplog 广播，最终一致性
- **TLS 加密** — TLS 1.3 支持，客户端与副本连接均可加密
- **密码认证** — AUTH 密码验证
- **热备份** — 基于 RocksDB Checkpoint，秒级硬链接备份
- **HTTP 章节接口** — 只读 HTTP API，HMAC-SHA256 签名 URL 防遍历，令牌桶限流，前端可直接加载小说内容
- **配置文件** — Redis conf 风格配置文件，CLI 仅保留启动开关，安全默认值
- **交互式安装** — install.sh 支持 TTY 交互配置端口/数据目录/密码等

## 支持命令

| 类别 | 命令 |
|---|---|
| 读写 | GET, SET, DEL, MGET, MSET, EXISTS, SETNX, STRLEN, APPEND, SETRANGE, GETSET |
| Hash | HSET, HGET, HDEL, HLEN, HGETALL, HKEYS, HVALS, HEXISTS |
| 扫描 | SCAN (cursor + MATCH + COUNT), KEYS (glob) |
| 计数 | INCR, INCRBY, DECR, DECRBY |
| 数据库 | SELECT, DBSIZE, FLUSHDB, FLUSHALL |
| 备份 | SAVE, BGSAVE |
| 连接 | PING, ECHO, QUIT, AUTH, COMMAND, CONFIG, INFO, CLIENT, HELLO, RESET |
| 复制 | REPLCONF, PSYNC |
| HTTP | GET /v1/data/{key}?sign=xxx&t=timestamp (只读，签名验证) |

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

### 子命令

- **`gen-certs`** — 生成自签名 ECDSA P-256 TLS 证书
- **`gen-secret`** — 生成随机 hex 密码（用于 `requirepass` / `http-secret`）
- **`migrate-hash-prefix`** — 将旧版本 hash 内部前缀（`H:` / `HM:`）迁移到新版本（`__novelkv:h:` / `__novelkv:hm:`），详见下方[升级指南](#从-v130-及更早版本升级)

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
# dict-size 256kb
# zstd-train-bytes 10000000
```

## HTTP 章节接口

HTTP 只读接口供前端直接加载小说章节内容，无需中间层。采用 HMAC-SHA256 签名 URL 防止恶意遍历和未授权调用。需在配置文件设置 `http-port` 和 `http-secret`，并加 `--enable-http` 启动。

### URL 格式

```
GET /v1/data/{key}?sign=xxx&t=123456789
```

- `key` — RocksDB 中的 key
- `sign` — HMAC-SHA256 签名（hex 编码，64 字符）
- `t` — Unix 时间戳（十进制），服务端校验不超过 TTL

### 签名算法

```
sign = hex(HMAC-SHA256(secret, key + t))
```

多语言生成示例：

```python
# Python
import hmac, hashlib, time

secret = b"mysecret"
key = "chapter1"
t = str(int(time.time()))
sign = hmac.new(secret, (key + t).encode(), hashlib.sha256).hexdigest()
url = f"/v1/data/{key}?sign={sign}&t={t}"
```

```php
// PHP
$secret = "mysecret";
$key = "chapter1";
$t = (string)time();
$sign = hash_hmac("sha256", $key . $t, $secret);
$url = "/v1/data/{$key}?sign={$sign}&t={$t}";
```

```go
// Go
package main

import (
    "crypto/hmac"
    "crypto/sha256"
    "encoding/hex"
    "fmt"
    "strconv"
    "time"
)

func main() {
    secret := []byte("mysecret")
    key := "chapter1"
    t := strconv.FormatInt(time.Now().Unix(), 10)
    mac := hmac.New(sha256.New, secret)
    mac.Write([]byte(key + t))
    sign := hex.EncodeToString(mac.Sum(nil))
    fmt.Printf("/v1/data/%s?sign=%s&t=%s\n", key, sign, t)
}
```

```java
// Java
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.time.Instant;

public class SignUrl {
    public static void main(String[] args) throws Exception {
        String secret = "mysecret";
        String key = "chapter1";
        String t = String.valueOf(Instant.now().getEpochSecond());
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(secret.getBytes(), "HmacSHA256"));
        StringBuilder sb = new StringBuilder();
        for (byte b : mac.doFinal((key + t).getBytes())) {
            sb.append(String.format("%02x", b));
        }
        System.out.printf("/v1/data/%s?sign=%s&t=%s%n", key, sb, t);
    }
}
```

```javascript
// Node.js
const crypto = require("crypto");

const secret = "mysecret";
const key = "chapter1";
const t = Math.floor(Date.now() / 1000).toString();
const sign = crypto.createHmac("sha256", secret).update(key + t).digest("hex");
const url = `/v1/data/${key}?sign=${sign}&t=${t}`;
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
tar xzf novelkv-v1.4.0-linux-x86_64.tar.gz
cd novelkv-v1.4.0-linux-x86_64
sudo ./install.sh
```

`install.sh` 检测到 TTY 时会交互式询问监听地址/端口/数据目录/密码；非 TTY 环境（CI/脚本）使用默认值，可用参数覆盖：

```
sudo ./install.sh [OPTIONS]

选项：
  --prefix PATH        安装路径前缀 (默认: /usr/local)
  --host ADDR          监听地址 (默认: 0.0.0.0)
  --port PORT          监听端口 (默认: 6379)
  --data PATH          数据目录 (默认: /var/lib/novelkv)
  --password PASS      认证密码
  --non-interactive    非交互模式，使用默认值/命令行参数
```

安装后编辑配置文件：

```bash
sudo vim /etc/novelkv/novelkv.conf
sudo systemctl start novelkv
sudo systemctl status novelkv
sudo journalctl -u novelkv -f
```

systemd 服务默认使用 `--config /etc/novelkv/novelkv.conf`，可在 `/etc/novelkv/novelkv.env` 中追加 CLI 覆盖参数。

### 从 v1.3.0 及更早版本升级

v1.4.0 将 hash 内部前缀从 `H:` / `HM:` 重命名为 `__novelkv:h:` / `__novelkv:hm:`，以避免与以 `H:`/`HM:` 开头的用户键名冲突。**已有 hash 数据的部署升级前必须运行迁移工具**：

```bash
# 1. 停止服务
sudo systemctl stop novelkv

# 2. 替换二进制（用新版本 install.sh 或手动 cp）
sudo cp novelkv /usr/local/bin/novelkv

# 3. 预览迁移量（不写入）
sudo novelkv migrate-hash-prefix -d /var/lib/novelkv --dry-run

# 4. 执行迁移
sudo novelkv migrate-hash-prefix -d /var/lib/novelkv

# 5. 启动服务
sudo systemctl start novelkv
```

迁移工具支持 `--config` 从配置文件读取 data 目录：

```bash
sudo novelkv migrate-hash-prefix --config /etc/novelkv/novelkv.conf --dry-run
```

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

**功能正确性测试**（pytest + redis-py，100 个用例覆盖命令契约与计数器一致性）：

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r tests/requirements.txt
zig build
python -m pytest tests/ -v
```

测试覆盖：
- `test_string_lifecycle.py` — SET/GET/DEL/EXISTS/TYPE/STRLEN/MGET/MSET 对称性 + DBSIZE 归零
- `test_hash_lifecycle.py` — HSET/HGET/HDEL/DEL hash/EXISTS/TYPE/HLEN/HKEYS/HVALS/HGETALL
- `test_scan_keys.py` — SCAN cursor 终止、KEYS glob、内部键不泄漏
- `test_counters.py` — DBSIZE 与 INFO live_data_size 在每次写/删后一致
- `test_type_consistency.py` — 同一 key 在 TYPE/EXISTS/DBSIZE/SCAN/KEYS 视角下一致
- `test_prefix_collision.py` — 用户键名以 H:/HM: 开头的边界情况

**存储层单元测试**：

```bash
zig build test
```

## 技术架构

```
src/main.zig         — CLI 入口，功能开关，信号处理，子命令 (gen-certs/gen-secret/migrate-hash-prefix)
src/config.zig       — Redis conf 风格配置文件解析器
src/server.zig       — TCP 服务，RESP 协议解析，连接管理
src/command.zig      — 命令分发与处理（string/hash/scan/连接/复制）
src/storage.zig      — RocksDB 封装，Column Family，RwLock 并发，原子计数器
src/resp.zig         — RESP 协议写入（RESP2/RESP3 双格式）
src/log.zig          — 分级日志
src/replication.zig  — 主从复制，Oplog 广播
src/tls_adapter.zig  — TLS 适配器
src/http_server.zig  — HTTP 只读章节接口（签名 URL + 限流 + CORS）
tests/               — pytest 功能正确性测试套件（100 用例）
```

## 存储引擎调优

基于 36.5 万真实中文小说章节（单 key 平均 7.3 KB）的实测数据。

### Compression Level（Zstd 压缩级别）

固定 block-size=128kb，无字典：

| 级别 | SST 大小 | 压缩比 | 写入速度 |
|------|----------|--------|----------|
| L1 | 1266 MB | 2.05x | 1757 k/s |
| L3 | 1122 MB | 2.31x | 1692 k/s |
| **L9（默认）** | **1046 MB** | **2.48x** | **1800 k/s** |
| L19 | 932 MB | 2.79x | 804 k/s |

L9 是速度与压缩比的最佳平衡点。L19 压缩比更高但写入速度减半。

### Block Size（SST Block 大小）

固定 compression-level=9，无字典：

| Block Size | SST 大小 | 压缩比 | 写入速度 |
|-----------|----------|--------|----------|
| 4KB | 1354 MB | 1.92x | 1755 k/s |
| 16KB | 1228 MB | 2.11x | 1682 k/s |
| 32KB | 1165 MB | 2.23x | 1722 k/s |
| 64KB | 1102 MB | 2.35x | 1725 k/s |
| **128KB（默认）** | **1046 MB** | **2.48x** | **1730 k/s** |
| 256KB | 992 MB | 2.62x | 1739 k/s |
| 512KB | 955 MB | 2.72x | 1680 k/s |
| 1MB | 917 MB | 2.83x | 1762 k/s |

Block size 越大压缩越好（压缩器上下文更多），写入速度基本不受影响。128KB 之后收益收窄。注意大 block 的代价：随机读取时即使只需要 1 字节也要加载整个 block。对于完整章节读取场景，可考虑 256KB。

### Zstd 字典压缩

| 方案 | SST 大小 | 压缩比 | Block Cache 占用 |
|------|----------|--------|-----------------|
| L9 无字典 | 1046 MB | 2.48x | 0% |
| L9 + 字典(256KB) | 951 MB | 2.73x | ~25%（63MB/256MB） |

字典压缩带来约 8% 额外压缩收益，但字典构建缓冲占用约 25% 的 Block Cache。磁盘空间换内存缓存，对读性能场景不划算。默认关闭，如需开启在配置文件中设置 `dict-size 256kb` 和 `zstd-train-bytes 10000000`。

## 性能参考

基于真实中文小说章节数据的实测结果（Zstd 字典压缩，level 9，128KB block size）。

### 实测数据

| 指标 | 值 |
|------|-----|
| Key 数量 | 197.2 万 |
| 单 key 平均原始大小 | 7.5 KB |
| 原始数据总量 | 14.0 GB |
| SST 磁盘占用 | 5.1 GB |
| **压缩比** | **2.73x** |
| 空闲 RSS | ~26 MB |
| Block Cache 容量 | 256 MB |
| 导入速度（单连接 TLS） | ~200 keys/s |

### 容量预估

基于实测数据的单 key 平均值（原始 7.5 KB，压缩后 2.7 KB）线性推算：

| 规模 | 原始数据 | SST 占用 | Block Cache 建议 | 磁盘需求 |
|------|----------|----------|-----------------|---------|
| 100 万 | 7 GB | 2.6 GB | 256 MB | 3 GB |
| 1000 万 | 72 GB | 27 GB | 256 MB | 30 GB |
| 5000 万 | 362 GB | 135 GB | 1 GB | 140 GB |
| 1 亿 | 724 GB | 270 GB | 2-4 GB | 280 GB |

> 千万级当前默认配置即可支撑，仅需磁盘空间。亿级建议调大 `block-cache-size` 和 `max-write-buffer-number`，RocksDB 本身为十亿级 key 设计，无架构瓶颈。

## License

MIT
