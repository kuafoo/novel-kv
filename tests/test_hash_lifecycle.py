"""Hash 类型生命周期测试。

重点覆盖本次发现的 bug:
- DEL hash_key 必须清理 HM: meta + H: 字段，DBSIZE 归零
- EXISTS hash_key 必须返回 1
- TYPE hash_key 必须返回 'hash'
- HDEL 后 DBSIZE 与 HLEN 一致
"""
import pytest
import redis  # noqa: F401  (用于 WRONGTYPE 测试)


class TestHashBasic:
    def test_hset_returns_new_fields(self, r):
        assert r.hset("h", "f1", "v1") == 1
        assert r.hset("h", "f1", "v2") == 0  # 覆盖，不算新字段
        assert r.hset("h", "f2", "v2") == 1

    def test_hget(self, r):
        r.hset("h", "f1", "v1")
        assert r.hget("h", "f1") == b"v1"
        assert r.hget("h", "nope") is None

    def test_hgetall(self, r):
        r.hset("h", "f1", "v1")
        r.hset("h", "f2", "v2")
        assert r.hgetall("h") == {b"f1": b"v1", b"f2": b"v2"}

    def test_hkeys_hvals(self, r):
        r.hset("h", "f1", "v1")
        r.hset("h", "f2", "v2")
        assert set(r.hkeys("h")) == {b"f1", b"f2"}
        assert set(r.hvals("h")) == {b"v1", b"v2"}

    def test_hlen(self, r):
        r.hset("h", "f1", "v1")
        r.hset("h", "f2", "v2")
        assert r.hlen("h") == 2

    def test_hexists(self, r):
        r.hset("h", "f1", "v1")
        assert r.hexists("h", "f1") is True
        assert r.hexists("h", "nope") is False


class TestHashDelete:
    def test_hdel_single_field(self, r):
        r.hset("h", "f1", "v1")
        r.hset("h", "f2", "v2")
        assert r.hdel("h", "f1") == 1
        assert r.hlen("h") == 1
        assert r.hexists("h", "f2") is True

    def test_hdel_all_fields_removes_hash(self, r):
        """关键：HDEL 所有字段后 hash 应该不存在。"""
        r.hset("h", "f1", "v1")
        r.hset("h", "f2", "v2")
        r.hdel("h", "f1", "f2")
        assert r.hlen("h") == 0
        assert r.type("h") == b"none"
        assert r.exists("h") == 0
        # DBSIZE 必须归零
        assert r.dbsize() == 0

    def test_hdel_nonexistent_field(self, r):
        r.hset("h", "f1", "v1")
        assert r.hdel("h", "nope") == 0
        assert r.hlen("h") == 1

    def test_del_hash_key(self, r):
        """关键回归：DEL hash_key 必须清空所有字段 + meta + DBSIZE 归零。"""
        r.hset("h", "f1", "v" * 500)
        r.hset("h", "f2", "w" * 500)
        r.hset("h", "f3", "x" * 500)
        assert r.dbsize() == 1  # hash 算 1 个用户键

        deleted = r.delete("h")
        assert deleted == 1

        # 全面验证 hash 已彻底消失
        assert r.dbsize() == 0, "DBSIZE 必须归零（meta 应被清理）"
        assert r.exists("h") == 0
        assert r.type("h") == b"none"
        assert r.hlen("h") == 0
        assert r.hget("h", "f1") is None
        assert r.hgetall("h") == {}

    def test_del_multiple_hashes(self, r):
        r.hset("h1", "f", "v")
        r.hset("h2", "f", "v")
        r.hset("h3", "f", "v")
        assert r.dbsize() == 3
        assert r.delete("h1", "h2", "h3") == 3
        assert r.dbsize() == 0

    def test_del_mixed_string_and_hash(self, r):
        """DEL 命令同时处理 string 和 hash。"""
        r.set("s1", "v")
        r.hset("h1", "f", "v")
        r.set("s2", "v")
        assert r.dbsize() == 3
        assert r.delete("s1", "h1", "s2") == 3
        assert r.dbsize() == 0


class TestHashExistsAndType:
    def test_exists_hash_returns_1(self, r):
        """关键回归：EXISTS hash_key 应返回 1。"""
        r.hset("h", "f", "v")
        assert r.exists("h") == 1

    def test_type_hash(self, r):
        """关键回归：TYPE hash_key 应返回 'hash'。"""
        r.hset("h", "f", "v")
        assert r.type("h") == b"hash"

    def test_type_after_hdel_all(self, r):
        r.hset("h", "f", "v")
        r.hdel("h", "f")
        assert r.type("h") == b"none"

    def test_wrongtype_operation(self, r):
        """对 string key 调用 hash 命令应返回 WRONGTYPE。"""
        r.set("s", "v")
        with pytest.raises(redis.exceptions.ResponseError) as exc:
            r.hget("s", "f")
        assert "WRONGTYPE" in str(exc.value)


class TestHashCounters:
    def test_dbsize_counts_hash_as_one(self, r):
        """hash 应该算作 1 个用户键，不论字段数。"""
        r.hset("h", "f1", "v1")
        assert r.dbsize() == 1
        r.hset("h", "f2", "v2")
        r.hset("h", "f3", "v3")
        assert r.dbsize() == 1  # 仍是 1

    def test_dbsize_with_multiple_hashes(self, r):
        r.hset("h1", "f", "v")
        r.hset("h2", "f", "v")
        r.hset("h3", "f", "v")
        assert r.dbsize() == 3

    def test_dbsize_string_plus_hash(self, r):
        r.set("s1", "v")
        r.set("s2", "v")
        r.hset("h1", "f", "v")
        assert r.dbsize() == 3
