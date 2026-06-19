# NovelKV Correctness Test Suite

针对 NovelKV 命令语义和计数器一致性的功能正确性测试。

## 运行

```bash
# 安装依赖（首次）
python3 -m venv .venv
source .venv/bin/activate
pip install -r tests/requirements.txt

# 构建 NovelKV 二进制（必须）
zig build

# 运行全部测试
python -m pytest tests/

# 运行某个测试文件
python -m pytest tests/test_hash_lifecycle.py

# 运行单个测试
python -m pytest tests/test_hash_lifecycle.py::TestHashDelete::test_del_hash_key

# 显示详细输出
python -m pytest tests/ -v
```

测试启动时会在 `/tmp/nv_pytest_<port>/` 创建独立的数据目录，session 结束自动清理。
每个测试函数执行前会 `FLUSHDB` 所有 16 个 db，保证隔离。

## 测试覆盖

| 文件 | 覆盖范围 |
|---|---|
| `test_string_lifecycle.py` | SET/GET/DEL/EXISTS/TYPE/STRLEN/MGET/MSET 对称性，DEL 后 DBSIZE 归零 |
| `test_hash_lifecycle.py` | HSET/HGET/HDEL/DEL/EXISTS/TYPE/HLEN/HKEYS/HVALS/HGETALL + WRONGTYPE |
| `test_scan_keys.py` | SCAN cursor 终止、KEYS glob、内部键不泄漏、COUNT 提示行为 |
| `test_counters.py` | DBSIZE 和 live_data_size 在每次写/删后保持一致 |
| `test_type_consistency.py` | 同一 key 在 TYPE/EXISTS/DBSIZE/SCAN/KEYS 视角下一致 |
| `test_prefix_collision.py` | 用户键名以 H:/HM: 开头的合法边界 |

## 设计原则

1. **对称性测试**：每个写入路径都要有对应的删除路径验证（写 → 删 → 计数归零）
2. **跨命令一致性**：DBSIZE、EXISTS、SCAN、TYPE、KEYS 对同一 key 的认知必须一致
3. **内部键不泄漏**：`__novelkv:*` 前缀的内部键不应出现在用户可见的命令结果中
4. **边界情况**：用户键名以 H:/HM: 等容易冲突的前缀开头必须正常工作

## 已知限制

- `__novelkv:` 是 NovelKV 保留前缀（类似 Redis 的 `__redis_`），
  用户主动使用该前缀写入是 undefined behavior（可能与内部键冲突）
- 长跑稳定性、压缩比等性能维度由项目根目录的 `stability_*.py` / `compress_test.py` 等覆盖，
  本目录只测功能正确性
