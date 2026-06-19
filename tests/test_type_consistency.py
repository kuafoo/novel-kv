"""类型一致性测试：同一 key 在 TYPE / EXISTS / DBSIZE / SCAN / KEYS 视角下必须一致。

覆盖本次发现的 bug：TYPE 返回 none 但 hash 数据还在；EXISTS 返回 0 但 SCAN 看到。
"""
import pytest
import redis


def _scan_all(r):
    cursor = 0
    keys: list[bytes] = []
    while True:
        cursor, batch = r.scan(cursor=cursor, count=100)
        keys.extend(batch)
        if cursor == 0:
            break
    return set(keys)


class TestStringConsistency:
    def test_all_views_agree_for_string(self, r):
        r.set("k", "v")
        assert r.type("k") == b"string"
        assert r.exists("k") == 1
        assert r.get("k") == b"v"
        assert b"k" in _scan_all(r)
        assert b"k" in set(r.keys("*"))
        assert r.dbsize() == 1

    def test_all_views_agree_after_del(self, r):
        r.set("k", "v")
        r.delete("k")
        assert r.type("k") == b"none"
        assert r.exists("k") == 0
        assert r.get("k") is None
        assert b"k" not in _scan_all(r)
        assert b"k" not in set(r.keys("*"))
        assert r.dbsize() == 0


class TestHashConsistency:
    def test_all_views_agree_for_hash(self, r):
        """关键回归：hash 在所有命令视角下必须存在。"""
        r.hset("h", "f", "v")
        assert r.type("h") == b"hash"
        assert r.exists("h") == 1
        assert r.hgetall("h") == {b"f": b"v"}
        assert b"h" in _scan_all(r)
        assert b"h" in set(r.keys("*"))
        assert r.dbsize() == 1

    def test_all_views_agree_after_del_hash(self, r):
        r.hset("h", "f", "v")
        r.delete("h")
        assert r.type("h") == b"none"
        assert r.exists("h") == 0
        assert r.hgetall("h") == {}
        assert b"h" not in _scan_all(r)
        assert b"h" not in set(r.keys("*"))
        assert r.dbsize() == 0

    def test_all_views_agree_after_hdel_all(self, r):
        r.hset("h", "f1", "v1")
        r.hset("h", "f2", "v2")
        r.hdel("h", "f1", "f2")
        assert r.type("h") == b"none"
        assert r.exists("h") == 0
        assert r.hgetall("h") == {}
        assert b"h" not in _scan_all(r)
        assert b"h" not in set(r.keys("*"))
        assert r.dbsize() == 0


class TestMixedTypesConsistency:
    def test_string_and_hash_coexist(self, r):
        r.set("s", "v")
        r.hset("h", "f", "v")
        assert r.dbsize() == 2
        assert set(r.keys("*")) == {b"s", b"h"}
        assert r.type("s") == b"string"
        assert r.type("h") == b"hash"

    def test_same_key_name_string_or_hash_not_both(self, r):
        """同一 key 名不能既是 string 又是 hash。"""
        r.set("shared", "v")
        # 尝试对该 key 做 hash 操作应 WRONGTYPE
        with pytest.raises(redis.exceptions.ResponseError):
            r.hset("shared", "f", "v")
        assert r.type("shared") == b"string"
        assert r.dbsize() == 1

    def test_delete_string_and_hash_same_name_pattern(self, r):
        """不同 key 名（一个 string 一个 hash）同时 DEL。"""
        r.set("k_str", "v")
        r.hset("k_hash", "f", "v")
        r.delete("k_str", "k_hash")
        assert r.dbsize() == 0
        assert r.exists("k_str", "k_hash") == 0


class TestWrongTypeGuards:
    """对 string key 调用 hash 命令应返回 WRONGTYPE，反之亦然。"""

    def test_hget_on_string(self, r):
        r.set("s", "v")
        with pytest.raises(redis.exceptions.ResponseError) as exc:
            r.hget("s", "f")
        assert "WRONGTYPE" in str(exc.value)

    def test_hset_on_string(self, r):
        r.set("s", "v")
        with pytest.raises(redis.exceptions.ResponseError):
            r.hset("s", "f", "v")
        # 原值不变
        assert r.get("s") == b"v"

    def test_get_on_hash_returns_wrongtype(self, r):
        r.hset("h", "f", "v")
        with pytest.raises(redis.exceptions.ResponseError):
            r.get("h")
