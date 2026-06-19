"""前缀冲突边界测试。

设计原则：
- `__novelkv:` 是 NovelKV 保留前缀（类似 Redis 的 `__redis_`），
  用户主动使用该前缀是 undefined behavior。
- `H:` / `HM:` 是合法用户键名前缀（早期版本曾被用作内部 hash 前缀，
  v1.3.1 后改为 __novelkv:h:/__novelkv:hm: 以避免冲突），
  用户键名以 H:/HM: 开头必须正常工作。
"""
import pytest


class TestUserKeyPrefixCollision:
    """用户键名以 H: / HM: 开头（合法，必须正常工作）。"""

    @pytest.mark.parametrize("user_key", [
        "H:mystring",
        "HM:mystring",
        "H:",
        "HM:",
        "H",
        "HM",
        "HashKey",
        "HMPrefix",
    ])
    def test_string_with_h_prefix(self, r, user_key):
        """SET/GET/DEL 用户键名以 H: / HM: 开头。"""
        r.set(user_key, "value")
        assert r.get(user_key) == b"value"
        assert r.exists(user_key) == 1
        assert r.type(user_key) == b"string"
        keys = set(r.keys("*"))
        assert user_key.encode() in keys
        assert r.dbsize() == 1
        r.delete(user_key)
        assert r.exists(user_key) == 0
        assert r.dbsize() == 0

    @pytest.mark.parametrize("hash_key", [
        "H:myhash",
        "HM:myhash",
        "H:",
        "HM:",
    ])
    def test_hash_with_h_prefix(self, r, hash_key):
        """HSET/HGETALL 用户 hash 键名以 H: / HM: 开头。"""
        r.hset(hash_key, "f1", "v1")
        r.hset(hash_key, "f2", "v2")
        assert r.hlen(hash_key) == 2
        assert r.hget(hash_key, "f1") == b"v1"
        assert r.hgetall(hash_key) == {b"f1": b"v1", b"f2": b"v2"}
        assert r.type(hash_key) == b"hash"
        assert r.exists(hash_key) == 1
        assert r.dbsize() == 1
        keys = set(r.keys("*"))
        assert hash_key.encode() in keys
        r.delete(hash_key)
        assert r.dbsize() == 0
        assert r.exists(hash_key) == 0


class TestPrefixAndUserHashCoexistence:
    """用户键名 H:xxx 和用户 hash 键名同时存在不应冲突。"""

    def test_h_prefix_string_and_normal_hash(self, r):
        r.set("H:mystring", "string_val")
        r.hset("normal_hash", "f", "v")
        assert r.get("H:mystring") == b"string_val"
        assert r.hget("normal_hash", "f") == b"v"
        assert r.dbsize() == 2
        # SCAN 必须两个都看到
        keys = set(r.keys("*"))
        assert b"H:mystring" in keys
        assert b"normal_hash" in keys

    def test_two_hashes_with_h_prefix(self, r):
        """两个 hash：一个用户键名以 H: 开头，一个正常键名。"""
        r.hset("H:userhash", "f1", "v1")
        r.hset("normalhash", "f2", "v2")
        assert r.dbsize() == 2
        assert r.hget("H:userhash", "f1") == b"v1"
        assert r.hget("normalhash", "f2") == b"v2"

    def test_del_one_hash_doesnt_affect_other(self, r):
        r.hset("H:userhash", "f", "v")
        r.hset("normalhash", "f", "v")
        r.delete("H:userhash")
        assert r.dbsize() == 1
        assert r.hget("normalhash", "f") == b"v"


class TestInternalPrefixNotUserVisible:
    """内部前缀在用户视角下完全不可见。"""

    def test_no_dunder_novelkv_in_scan(self, r):
        """任何操作后 SCAN 都不应返回 __novelkv: 开头的键。"""
        r.set("k1", "v")
        r.set("k2", "v")
        r.hset("h1", "f1", "v1")
        r.hset("h1", "f2", "v2")
        r.hset("h2", "f", "v")
        for k in r.keys("*"):
            assert not k.startswith(b"__novelkv:"), f"内部键泄漏到 KEYS: {k!r}"

        cursor = 0
        while True:
            cursor, batch = r.scan(cursor=cursor, count=10)
            for k in batch:
                assert not k.startswith(b"__novelkv:"), f"内部键泄漏到 SCAN: {k!r}"
            if cursor == 0:
                break

    def test_user_writes_to_meta_prefix_at_own_risk(self, r):
        """__novelkv: 前缀是 NovelKV 保留的内部命名空间。

        用户主动写入该前缀是 undefined behavior（可能被覆盖、不计入 DBSIZE 等）。
        本测试只验证：用户写入后仍能读回（不会被静默拒绝），
        但不断言 DBSIZE 等行为（因为内部 key 与用户 key 在此命名空间重叠）。
        """
        r.set("__novelkv:user:custom_key", "custom_value")
        # 至少能读回
        assert r.get("__novelkv:user:custom_key") == b"custom_value"
