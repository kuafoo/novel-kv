"""SCAN/KEYS 命令测试。

覆盖本次发现的 bug:
- 内部键 (__novelkv:*) 不应泄漏到 SCAN/KEYS 结果
- SCAN cursor 必须最终终止（返回 0）
- hash 键应在 SCAN/KEYS 中可见（与 Redis 一致）
"""
import pytest


def _scan_all(r, match=None, count=100):
    """用 SCAN 游标完整遍历，返回所有 key 的集合。"""
    cursor = 0
    keys: list[bytes] = []
    while True:
        if match:
            cursor, batch = r.scan(cursor=cursor, match=match, count=count)
        else:
            cursor, batch = r.scan(cursor=cursor, count=count)
        keys.extend(batch)
        if cursor == 0:
            break
    return set(keys)


class TestScan:
    def test_scan_empty_db(self, r):
        cursor, keys = r.scan(cursor=0)
        assert cursor == 0
        assert keys == []

    def test_scan_returns_all_user_keys(self, r):
        r.set("k1", "v")
        r.set("k2", "v")
        r.hset("h1", "f", "v")
        result = _scan_all(r)
        assert result == {b"k1", b"k2", b"h1"}

    def test_scan_terminates_with_small_count(self, r):
        """关键回归：SCAN cursor 必须终止，不能无限循环。"""
        for i in range(20):
            r.set(f"k{i:03d}", "v")
        cursor = 0
        rounds = 0
        seen: set[bytes] = set()
        while rounds < 1000:  # 安全上限
            cursor, batch = r.scan(cursor=cursor, count=2)
            seen.update(batch)
            rounds += 1
            if cursor == 0:
                break
        assert cursor == 0, f"SCAN never terminated after {rounds} rounds"
        assert len(seen) == 20

    def test_scan_no_internal_keys_leak(self, r):
        """关键回归：__novelkv:* 等内部前缀不应出现在 SCAN 中。"""
        r.set("user:k1", "v")
        r.set("user:k2", "v")
        r.hset("user:hash", "f1", "v1")
        r.hset("user:hash", "f2", "v2")
        result = _scan_all(r)
        # 不应有内部前缀（注意：用户键名 H:/HM: 开头是合法的，不算内部）
        for k in result:
            assert not k.startswith(b"__novelkv:"), f"内部键泄漏: {k!r}"
        # hash 键应作为 user:hash 可见（不是 HM:user:hash）
        assert b"user:hash" in result
        assert b"user:k1" in result
        assert b"user:k2" in result

    def test_scan_with_match_glob(self, r):
        r.set("user:1", "v")
        r.set("user:2", "v")
        r.set("admin:1", "v")
        r.hset("user:hash", "f", "v")
        result = _scan_all(r, match="user:*")
        assert result == {b"user:1", b"user:2", b"user:hash"}

    def test_scan_count_default(self, r):
        """COUNT 是提示，不保证精确数量，但应返回所有 key。"""
        for i in range(50):
            r.set(f"k{i:03d}", "v")
        result = _scan_all(r, count=10)
        assert len(result) == 50


class TestKeys:
    def test_keys_empty(self, r):
        assert r.keys("*") == []

    def test_keys_all(self, r):
        r.set("k1", "v")
        r.set("k2", "v")
        r.hset("h1", "f", "v")
        result = set(r.keys("*"))
        assert result == {b"k1", b"k2", b"h1"}

    def test_keys_glob_pattern(self, r):
        r.set("user:1", "v")
        r.set("user:2", "v")
        r.set("admin:1", "v")
        result = set(r.keys("user:*"))
        assert result == {b"user:1", b"user:2"}

    def test_keys_prefix_collision_h(self, r):
        """关键边界：用户键名以 H: 开头不应被当作内部 hash 字段过滤。"""
        r.set("H:mystring", "v")
        r.set("HM:mystring", "v")
        r.set("normal", "v")
        result = set(r.keys("*"))
        assert b"H:mystring" in result
        assert b"HM:mystring" in result
        assert b"normal" in result

    def test_keys_no_internal_meta(self, r):
        """写入数据后，__novelkv:meta:* 不应出现在 KEYS 中。"""
        r.set("k", "v")
        r.hset("h", "f", "v")
        for k in r.keys("*"):
            assert not k.startswith(b"__novelkv:")


class TestScanCursorStability:
    """SCAN 在并发写入下的 cursor 稳定性（弱保证：不重不漏可接受，但必须终止）。"""

    def test_scan_large_dataset_terminates(self, r):
        for i in range(500):
            r.set(f"key:{i:04d}", "v" * 100)
        cursor = 0
        rounds = 0
        seen: set[bytes] = set()
        while rounds < 10000:
            cursor, batch = r.scan(cursor=cursor, count=50)
            seen.update(batch)
            rounds += 1
            if cursor == 0:
                break
        assert cursor == 0
        assert len(seen) == 500
