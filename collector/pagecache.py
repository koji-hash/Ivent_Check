"""詳細ページの解析結果を保存しておくキャッシュ。

毎日すべての詳細ページを取りに行かないように、URL ごとに「解析済みの事実情報」と取得日時を保存する。
本文そのものは保存しない。
"""
from __future__ import annotations

import datetime as dt
import json
from pathlib import Path


class PageCache:
    def __init__(self, path: Path):
        self.path = path
        self.data: dict[str, dict] = json.loads(path.read_text()) if path.exists() else {}
        self.fetched = 0

    def get(self, url: str) -> dict | None:
        entry = self.data.get(url)
        return entry["record"] if entry else None

    def is_fresh(self, url: str, now: dt.datetime, max_age_days: float) -> bool:
        entry = self.data.get(url)
        if not entry:
            return False
        fetched = dt.datetime.fromisoformat(entry["fetchedAt"])
        return now - fetched < dt.timedelta(days=max_age_days)

    def put(self, url: str, record: dict | None, now: dt.datetime) -> None:
        self.data[url] = {"fetchedAt": now.isoformat(timespec="seconds"), "record": record}
        self.fetched += 1

    def retain(self, urls: set[str]) -> None:
        """一覧から消えたページは捨てる"""
        for url in list(self.data):
            if url not in urls:
                del self.data[url]

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self.data, ensure_ascii=False, indent=0, sort_keys=True) + "\n")
