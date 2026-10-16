"""イベント詳細ページから「場所」「日時」「料金」欄だけを読む（一覧に会場が無いとき用）。

解析結果（事実情報のみ）は PageCache に保存し、同じページは一定期間取り直さない。
"""
from __future__ import annotations

import datetime as dt
import re
import urllib.parse

from common import fetch, html_to_text

LABELED = re.compile(r"^[\s◆■●・<【\[]*({labels})\s*[>】\]]?\s*[:：]?\s*(.*)$")
PLACE_LABELS = "開催場所|実施場所|場\\s*所|会\\s*場|ところ"
TIME_LABELS = "開催日時|日\\s*時|時\\s*間|開催時間|と\\s*き"
PRICE_LABELS = "参加費|費\\s*用|料\\s*金|受講料|入場料|観覧料"
# 本文の入れ物としてよく使われる要素（ナビゲーションの「場所」などを拾わないように本文に絞る）
MAIN_BLOCKS = [
    r'<div id="tmp_contents"[^>]*>(.*?)<div id="(?:tmp_inquiry|tmp_footer|tmp_left)',
    r'<div[^>]+id="(?:main_body|main|contents|content)"[^>]*>(.*?)<(?:footer|div[^>]+id="(?:footer|side))',
    r"<main[^>]*>(.*?)</main>",
    r"<article[^>]*>(.*?)</article>",
]


def labeled_value(lines: list[str], labels: str) -> str | None:
    pattern = re.compile(LABELED.pattern.format(labels=labels))
    for i, line in enumerate(lines):
        if m := pattern.match(line):
            value = m.group(2).strip()
            if not value and i + 1 < len(lines):
                value = lines[i + 1].strip()
            # 「午前9時30分 / から / 午後5時15分 / まで」のように行が分かれている場合はつなげる
            j = i + (1 if m.group(2).strip() else 2)
            while j < len(lines) and j < i + 6 and re.match(r"^(から|まで|より|[~〜～-]|午前|午後|正午|\d{1,2}[時:])", lines[j]):
                value += lines[j]
                j += 1
            if value and len(value) >= 2:
                return value[:120]
    return None


def parse_detail(html: str) -> dict:
    """詳細ページから会場・時刻・料金だけを取り出す（本文は保存しない）"""
    body = html
    for pattern in MAIN_BLOCKS:
        if m := re.search(pattern, html, re.S):
            body = m.group(1)
            break
    lines = html_to_text(body).splitlines()
    return {
        "place": labeled_value(lines, PLACE_LABELS),
        "time": labeled_value(lines, TIME_LABELS),
        "price": labeled_value(lines, PRICE_LABELS),
    }


class DetailFetcher:
    """ソースごとに取得件数の上限を設けて詳細ページを読む"""

    def __init__(self, cache, max_fetch: int = 200):
        self.cache = cache
        self.budget = max_fetch

    def get(self, url: str, now: dt.datetime, soonest: dt.date | None = None, allowed_host: str | None = None) -> dict:
        max_age = 7 if soonest and (soonest - now.date()).days <= 3 else 60
        host_ok = allowed_host is None or urllib.parse.urlparse(url).netloc == allowed_host
        if host_ok and not self.cache.is_fresh(url, now, max_age) and self.budget > 0:
            self.budget -= 1
            try:
                self.cache.put(url, parse_detail(fetch(url)), now)
            except Exception as error:
                print(f"  ! {url}: {error}")
        return self.cache.get(url) or {}
