"""计数器一致性测试：DBSIZE 和 INFO live_data_size 必须在每次写/删后保持准确。

覆盖本次发现的 bug：删除 hash/字段后 live_data_size 没归零、DBSIZE 不准确。
"""
import pytest


def _live_data_size(info):
    """读取 INFO 中的 live_data_size 字段。"""
    return int(info("storage").get("live_data_size", "0"))


class TestDbsizeString:
    def test_empty(self, r):
        assert r.dbsize() == 0

    def test_set_increments(self, r):
        r.set("k1", "v")
        assert r.dbsize() == 1
        r.set("k2", "v")
        assert r.dbsize() == 2

    def test_overwrite_no_change(self, r):
        r.set("k", "v1")
        r.set("k", "v2")
        r.set("k", "v3")
        assert r.dbsize() == 1

    def test_del_decrements(self, r):
        r.set("k1", "v")
        r.set("k2", "v")
        r.delete("k1")
        assert r.dbsize() == 1
        r.delete("k2")
        assert r.dbsize() == 0

    def test_del_nonexistent_no_change(self, r):
        r.set("k", "v")
        # 删除不存在的 key 不应影响 DBSIZE
        r.delete("nope1", "nope2")
        assert r.dbsize() == 1


class TestDbsizeHash:
    def test_hset_one_hash(self, r):
        r.hset("h", "f1", "v")
        assert r.dbsize() == 1
        # 新字段不影响 DBSIZE
        r.hset("h", "f2", "v")
        r.hset("h", "f3", "v")
        assert r.dbsize() == 1

    def test_multiple_hashes(self, r):
        for i in range(10):
            r.hset(f"h{i}", "f", "v")
        assert r.dbsize() == 10

    def test_hdel_field_no_change(self, r):
        """HDEL 部分字段不应改变 DBSIZE（hash 仍存在）。"""
        r.hset("h", "f1", "v")
        r.hset("h", "f2", "v")
        r.hset("h", "f3", "v")
        assert r.dbsize() == 1
        r.hdel("h", "f1")
        assert r.dbsize() == 1

    def test_hdel_all_fields_decrement(self, r):
        """HDEL 所有字段后 hash 消失，DBSIZE 归零。"""
        r.hset("h", "f1", "v")
        r.hset("h", "f2", "v")
        assert r.dbsize() == 1
        r.hdel("h", "f1", "f2")
        assert r.dbsize() == 0

    def test_del_hash_decrement(self, r):
        """关键回归：DEL hash_key 必须使 DBSIZE 归零。"""
        r.hset("h", "f1", "v")
        r.hset("h", "f2", "v")
        r.hset("h", "f3", "v")
        assert r.dbsize() == 1
        r.delete("h")
        assert r.dbsize() == 0


class TestLiveDataSize:
    """INFO 中的 live_data_size 应反映所有用户数据的字节数。"""

    def test_empty(self, r, info):
        assert _live_data_size(info) == 0

    def test_string_set_reflects_size(self, r, info):
        r.set("k", "x" * 1000)
        # 1000 字节值 + 1 字节 key（不计入 live_data_size）
        assert _live_data_size(info) == 1000

    def test_string_overwrite_updates_size(self, r, info):
        r.set("k", "x" * 500)
        assert _live_data_size(info) == 500
        r.set("k", "x" * 1500)
        assert _live_data_size(info) == 1500

    def test_string_del_zeros_size(self, r, info):
        """关键回归：DEL string 后 live_data_size 归零。"""
        r.set("k", "x" * 1000)
        assert _live_data_size(info) == 1000
        r.delete("k")
        assert _live_data_size(info) == 0

    def test_hash_fields_reflect_size(self, r, info):
        r.hset("h", "f1", "x" * 100)
        r.hset("h", "f2", "x" * 200)
        # 字段值字节数（100 + 200）+ meta "2"（1 字节）
        assert _live_data_size(info) == 301

    def test_hash_del_zeros_size(self, r, info):
        """关键回归：DEL hash 后 live_data_size 必须归零（meta + 字段都清理）。"""
        r.hset("h", "f1", "x" * 500)
        r.hset("h", "f2", "x" * 500)
        size_with_hash = _live_data_size(info)
        assert size_with_hash > 1000

        r.delete("h")
        assert _live_data_size(info) == 0, "DEL hash 后 live_data_size 必须归零"

    def test_hdel_field_updates_size(self, r, info):
        """HDEL 部分字段：live_data_size 应减去对应字段值字节数。"""
        r.hset("h", "f1", "x" * 500)
        r.hset("h", "f2", "x" * 500)
        before = _live_data_size(info)

        r.hdel("h", "f1")
        after = _live_data_size(info)
        # live_data_size 应减少 500（f1 的值长度）
        # meta 长度可能从 "2" → "1" 不变（都是 1 字节）
        assert before - after == 500

    def test_hdel_all_zeros_size(self, r, info):
        """HDEL 所有字段后 meta 也被删，live_data_size 归零。"""
        r.hset("h", "f1", "x" * 100)
        r.hset("h", "f2", "x" * 200)
        r.hdel("h", "f1", "f2")
        assert _live_data_size(info) == 0


class TestCounterConsistency:
    """DBSIZE 与 KEYS 的数量必须一致。"""

    def test_dbsize_matches_scan_count(self, r):
        for i in range(30):
            r.set(f"k{i:03d}", "v")
        for i in range(5):
            r.hset(f"h{i}", "f", "v")

        dbsize = r.dbsize()
        keys = r.keys("*")
        assert dbsize == len(keys) == 35

    def test_consistency_after_partial_delete(self, r):
        for i in range(20):
            r.set(f"k{i:03d}", "v")
        # 删除一半
        for i in range(0, 20, 2):
            r.delete(f"k{i:03d}")
        assert r.dbsize() == len(r.keys("*")) == 10

    def test_db0_isolated(self, r):
        """SELECT 切换 db 后 DBSIZE 独立。"""
        r.set("k_db0", "v")
        assert r.dbsize() == 1

        r.execute_command("SELECT", 1)
        r.set("k_db1", "v")
        assert r.dbsize() == 1

        r.execute_command("SELECT", 0)
        assert r.dbsize() == 1
        assert r.keys("*") == [b"k_db0"]
