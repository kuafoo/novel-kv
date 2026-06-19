"""String 类型生命周期：SET → GET → DEL → 计数归零。

覆盖本次发现的 bug 模式：删除后 DBSIZE、EXISTS、TYPE 必须一致归零。
"""
import pytest


class TestStringBasic:
    def test_set_get_roundtrip(self, r):
        assert r.set("k", "hello") is True
        assert r.get("k") == b"hello"

    def test_set_overwrite(self, r):
        r.set("k", "v1")
        r.set("k", "v2")
        assert r.get("k") == b"v2"
        assert r.dbsize() == 1

    def test_set_empty_value(self, r):
        r.set("k", "")
        assert r.get("k") == b""
        assert r.dbsize() == 1

    def test_get_nonexistent(self, r):
        assert r.get("nope") is None

    def test_strlen(self, r):
        r.set("k", "hello")
        assert r.strlen("k") == 5
        assert r.strlen("nope") == 0


class TestStringDelete:
    def test_del_returns_count(self, r):
        r.set("k1", "v1")
        assert r.delete("k1") == 1
        assert r.delete("k1") == 0  # 已删除

    def test_del_multiple(self, r):
        r.set("a", "1")
        r.set("b", "2")
        r.set("c", "3")
        assert r.delete("a", "b", "c") == 3
        assert r.dbsize() == 0

    def test_del_mixed_existing_nonexistent(self, r):
        r.set("a", "1")
        r.set("b", "2")
        # mixed: a,b 存在，nope 不存在，应返回 2
        assert r.delete("a", "nope", "b") == 2

    def test_dbsize_after_del(self, r):
        """关键回归：DEL 后 DBSIZE 必须归零。"""
        r.set("k", "v" * 1000)
        assert r.dbsize() == 1
        r.delete("k")
        assert r.dbsize() == 0
        # 再次删除不存在的 key，DBSIZE 不变
        r.delete("k")
        assert r.dbsize() == 0


class TestStringExists:
    def test_exists_after_set(self, r):
        r.set("k", "v")
        assert r.exists("k") == 1

    def test_exists_nonexistent(self, r):
        assert r.exists("nope") == 0

    def test_exists_after_del(self, r):
        r.set("k", "v")
        r.delete("k")
        assert r.exists("k") == 0

    def test_exists_multiple(self, r):
        r.set("a", "1")
        r.set("b", "2")
        assert r.exists("a", "b", "nope") == 2


class TestStringType:
    def test_type_string(self, r):
        r.set("k", "v")
        assert r.type("k") == b"string"

    def test_type_nonexistent(self, r):
        assert r.type("nope") == b"none"

    def test_type_after_del(self, r):
        r.set("k", "v")
        r.delete("k")
        assert r.type("k") == b"none"


class TestStringSetNx:
    def test_setnx_new_key(self, r):
        assert r.setnx("k", "v1") is True
        assert r.get("k") == b"v1"

    def test_setnx_existing_key(self, r):
        r.set("k", "v1")
        assert r.setnx("k", "v2") is False
        assert r.get("k") == b"v1"


class TestStringMgetMset:
    def test_mset_mget(self, r):
        r.mset({"a": "1", "b": "2", "c": "3"})
        assert r.mget("a", "b", "c") == [b"1", b"2", b"3"]

    def test_mget_with_missing(self, r):
        r.set("a", "1")
        assert r.mget("a", "nope") == [b"1", None]
