"""Pytest fixtures: 自动启动一个独立的 NovelKV 实例供测试使用。

每个测试 session 启动一个实例，所有测试共享；db 通过 FLUSHDB 在测试间清理。
若需要隔离的实例，使用 `nv_instance` fixture（每个测试一个端口和数据目录）。
"""
from __future__ import annotations

import os
import shutil
import socket
import subprocess
import time
from pathlib import Path
from typing import Iterator

import pytest
import redis


PROJECT_ROOT = Path(__file__).resolve().parent.parent
NOVELKV_BIN = PROJECT_ROOT / "zig-out" / "bin" / "novelkv"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 16500  # 避开 6379/16379 等常用端口
DEFAULT_PASSWORD = "testpass"


def _free_port(start: int = 16500) -> int:
    """找一个可用端口。"""
    for port in range(start, start + 200):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.bind((DEFAULT_HOST, port))
            s.close()
            return port
        except OSError:
            continue
    raise RuntimeError("no free port")


def _wait_until_ready(port: int, password: str, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        try:
            r = redis.Redis(host=DEFAULT_HOST, port=port, password=password, socket_connect_timeout=0.5)
            r.ping()
            r.close()
            return
        except Exception as e:  # noqa: BLE001
            last_err = e
            time.sleep(0.1)
    raise RuntimeError(f"NovelKV did not become ready on port {port}: {last_err}")


class NovelKVInstance:
    """一个运行中的 NovelKV 实例。"""

    def __init__(self, process: subprocess.Popen, port: int, data_dir: Path, password: str):
        self.process = process
        self.port = port
        self.data_dir = data_dir
        self.password = password

    def client(self, **kwargs) -> redis.Redis:
        """返回一个已连接的 redis-py 客户端。"""
        return redis.Redis(
            host=DEFAULT_HOST,
            port=self.port,
            password=self.password,
            socket_connect_timeout=2.0,
            socket_timeout=5.0,
            **kwargs,
        )

    def stop(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)


@pytest.fixture(scope="session")
def nv_binary() -> Path:
    """确保 NovelKV 二进制存在。"""
    if not NOVELKV_BIN.exists():
        pytest.fail(f"NovelKV binary not found at {NOVELKV_BIN}. Run `zig build` first.")
    return NOVELKV_BIN


@pytest.fixture(scope="session")
def nv_instance(nv_binary: Path) -> Iterator[NovelKVInstance]:
    """启动一个 NovelKV 实例，session 结束时关闭。"""
    port = _free_port(DEFAULT_PORT)
    data_dir = Path(f"/tmp/nv_pytest_{port}")
    if data_dir.exists():
        shutil.rmtree(data_dir)
    data_dir.mkdir(parents=True)

    config_path = data_dir / "novelkv.conf"
    # 启用 dangerous 命令以便测试 FLUSHDB（清空数据库）。
    config_path.write_text(
        f"""host {DEFAULT_HOST}
port {port}
data {data_dir / "data"}
log-level warn
requirepass {DEFAULT_PASSWORD}
"""
    )

    log_file = data_dir / "novelkv.log"
    log_fp = log_file.open("w")

    proc = subprocess.Popen(
        [str(nv_binary), "--config", str(config_path), "--enable-dangerous"],
        stdout=log_fp,
        stderr=subprocess.STDOUT,
    )

    try:
        _wait_until_ready(port, DEFAULT_PASSWORD)
    except Exception:
        proc.terminate()
        log_fp.close()
        tail = log_file.read_text()[-4000:]
        pytest.fail(f"NovelKV failed to start. Log tail:\n{tail}")

    inst = NovelKVInstance(proc, port, data_dir, DEFAULT_PASSWORD)

    yield inst

    inst.stop()
    log_fp.close()
    # 保留日志和数据目录便于调试，session 结束清理
    shutil.rmtree(data_dir, ignore_errors=True)


@pytest.fixture()
def r(nv_instance: NovelKVInstance) -> Iterator[redis.Redis]:
    """每个测试一个干净的数据库 + 已连接的 redis 客户端。"""
    client = nv_instance.client()
    # 清空所有 db，保证测试间隔离
    for db in range(16):
        client.execute_command("SELECT", db)
        client.execute_command("FLUSHDB")
    client.execute_command("SELECT", 0)
    yield client
    client.close()


@pytest.fixture()
def info(r: redis.Redis):
    """便捷读取 INFO 解析后的字典。

    redis-py 的 r.info() 默认返回 dict；但 NovelKV 自定义 section（如 'storage'）
    可能不被识别，这里手动用 execute_command 取原始文本再解析。
    """

    def _info(section: str = "default") -> dict[str, str]:
        raw = r.execute_command("INFO", section)
        if isinstance(raw, dict):
            return {k: str(v) for k, v in raw.items()}
        if isinstance(raw, bytes):
            raw = raw.decode(errors="replace")
        out: dict[str, str] = {}
        for line in raw.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or ":" not in line:
                continue
            k, _, v = line.partition(":")
            out[k] = v
        return out

    return _info
