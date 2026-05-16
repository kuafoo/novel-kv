#!/usr/bin/env python3
"""Crawl Chinese novels from 00shu.la for compression benchmarking.
Multi-threaded version for faster downloading.
Target: 500MB-1GB of raw chapter text data.
"""
import os
import re
import sys
import time
import urllib.request
import urllib.error
from html.parser import HTMLParser
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

BASE_URL = "https://www.00shu.la"
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test-chapters")
TARGET_BYTES = 500 * 1024 * 1024  # 500MB target
DELAY = 0.15  # seconds between requests per thread
MAX_RETRIES = 3
NUM_WORKERS = 16  # concurrent download threads

size_lock = threading.Lock()
total_size_cache = [0]
novel_lock = threading.Lock()


class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_content = False
        self.skip_tags = {"script", "style", "div"}
        self.in_skip = 0
        self.parts = []

    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)
        if attrs_dict.get("id") == "content":
            self.in_content = True
            return
        if self.in_content and tag in self.skip_tags:
            self.in_skip += 1

    def handle_endtag(self, tag):
        if tag in self.skip_tags and self.in_skip > 0:
            self.in_skip -= 1

    def handle_data(self, data):
        if self.in_content and self.in_skip == 0:
            self.parts.append(data)

    def get_text(self):
        text = "".join(self.parts)
        text = text.replace("\xa0", " ")
        text = re.sub(r"\s{3,}", "\n\n", text)
        return text.strip()


import gzip
import io


def fetch(url):
    for attempt in range(MAX_RETRIES):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
                "Accept-Encoding": "gzip",
            })
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = resp.read()
                try:
                    data = gzip.decompress(data)
                except Exception:
                    pass
                return data.decode("utf-8", errors="replace")
        except (urllib.error.URLError, OSError) as e:
            if attempt < MAX_RETRIES - 1:
                time.sleep(1)
            else:
                return None


def get_novel_list(page=1):
    url = f"{BASE_URL}/shuku/{page}.html" if page > 1 else f"{BASE_URL}/shuku/"
    html = fetch(url)
    if not html:
        return []
    pattern = re.compile(r'href="https://www\.00shu\.la/book/(\d+)/"')
    return list(set(pattern.findall(html)))


def get_chapter_list(novel_id):
    prefix = novel_id[:2] if len(novel_id) >= 2 else novel_id
    url = f"{BASE_URL}/{prefix}/{novel_id}/"
    html = fetch(url)
    if not html:
        return []
    pattern = re.compile(rf'/{prefix}/{novel_id}/(\d+)\.html')
    return list(dict.fromkeys(pattern.findall(html)))


def download_chapter(novel_id, chapter_idx, chapter_id, novel_dir):
    fname = f"{chapter_idx+1:04d}_{chapter_id}.txt"
    fpath = os.path.join(novel_dir, fname)
    if os.path.exists(fpath):
        return os.path.getsize(fpath)

    prefix = novel_id[:2] if len(novel_id) >= 2 else novel_id
    url = f"{BASE_URL}/{prefix}/{novel_id}/{chapter_id}.html"
    html = fetch(url)
    if not html:
        return 0
    extractor = TextExtractor()
    try:
        extractor.feed(html)
    except Exception:
        return 0
    text = extractor.get_text()
    if len(text) <= 50:
        return 0

    with open(fpath, "w", encoding="utf-8") as f:
        f.write(text)
    time.sleep(DELAY)
    return len(text.encode("utf-8"))


def crawl_novel(novel_id):
    """Crawl all chapters of a novel. Returns (novel_id, bytes_downloaded, chapter_count)."""
    novel_dir = os.path.join(OUTPUT_DIR, f"novel_{novel_id}")

    # Skip if already crawled
    if os.path.exists(novel_dir):
        existing = len([f for f in os.listdir(novel_dir) if f.endswith(".txt")])
        if existing > 0:
            return novel_id, 0, existing

    # Get chapter list
    chapter_ids = get_chapter_list(novel_id)
    if not chapter_ids:
        return novel_id, 0, 0

    os.makedirs(novel_dir, exist_ok=True)
    print(f"  Novel {novel_id}: {len(chapter_ids)} chapters, downloading...")

    total_bytes = 0
    count = 0

    # Download chapters with thread pool within this novel
    with ThreadPoolExecutor(max_workers=8) as executor:
        futures = {}
        for i, ch_id in enumerate(chapter_ids):
            f = executor.submit(download_chapter, novel_id, i, ch_id, novel_dir)
            futures[f] = i

        for f in as_completed(futures):
            sz = f.result()
            if sz > 0:
                total_bytes += sz
                count += 1

    return novel_id, total_bytes, count


def get_total_size():
    total = 0
    for root, dirs, files in os.walk(OUTPUT_DIR):
        for f in files:
            if f.endswith(".txt"):
                total += os.path.getsize(os.path.join(root, f))
    return total


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    current_size = get_total_size()
    print(f"Current data size: {current_size / 1024 / 1024:.1f}MB")
    print(f"Target: {TARGET_BYTES / 1024 / 1024:.0f}MB")

    if current_size >= TARGET_BYTES:
        print("Already have enough data!")
        return

    # Collect novel IDs
    novel_ids = []
    for page in range(1, 30):
        ids = get_novel_list(page)
        if not ids:
            break
        novel_ids.extend(ids)
        print(f"Page {page}: found {len(ids)} novels")
        time.sleep(0.2)

    novel_ids = list(dict.fromkeys(novel_ids))
    # Skip already-crawled novels
    for nid in ["26612", "32864", "22257", "89880", "44739"]:
        if nid in novel_ids:
            novel_ids.remove(nid)
    print(f"Total novels to crawl: {len(novel_ids)}")

    # Crawl novels concurrently
    completed = 0
    with ThreadPoolExecutor(max_workers=NUM_WORKERS) as executor:
        futures = {executor.submit(crawl_novel, nid): nid for nid in novel_ids}

        for f in as_completed(futures):
            nid = futures[f]
            try:
                _, nbytes, nchapters = f.result()
                completed += 1
            except Exception as e:
                print(f"  Novel {nid} failed: {e}")
                completed += 1
                continue

            current = get_total_size()
            print(f"  [{completed}/{len(novel_ids)}] Novel {nid}: {nchapters} chapters, "
                  f"total: {current/1024/1024:.1f}MB")

            if current >= TARGET_BYTES:
                print("Reached target size! Stopping...")
                executor.shutdown(wait=False, cancel_futures=True)
                break

    print(f"\nFinal data size: {get_total_size() / 1024 / 1024:.1f}MB")


if __name__ == "__main__":
    main()
