"""宝塚市立公民館（中央・東・西）の催し。WordPress REST API から取得する。

日時は本文の「日時：」行をルールで読む。読めないもの（「毎月第2水曜日」など）は載せない。
"""
from __future__ import annotations

import datetime as dt
import re

from common import (build_event, fetch_json, find_time_range, html_to_text, keyword_categories,
                    merge_categories, nfkc)

API = "https://www.takarazuka-kominkan.jp/wp-json/wp/v2/{type}?per_page=50&page={page}&orderby=date&order=desc&_fields=id,link,title,content,date,modified"
SITE_URL = "https://www.takarazuka-kominkan.jp/"
SOURCE_NAME = "宝塚市立公民館"
LICENSE = "宝塚市立公民館ウェブサイト（再利用条件の明示なし）。名称・日時・会場などの事実情報とリンクのみ掲載"

HALLS = {"event_central": "中央公民館", "event_east": "東公民館", "event_west": "西公民館"}

LABEL_DATE = re.compile(r"^[\s◆■●・<【\[]*(?:開催)?(?:日\s*時|日\s*程|開催日|と\s*き|期\s*間)\s*[>】\]]?\s*[:：]?\s*(.+\d.*)$")
LABEL_PLACE = re.compile(r"^(?:場\s*所|会\s*場|ところ)\s*[:：]\s*(.+)$")
LABEL_PRICE = re.compile(r"^(?:参加費|受講料|料\s*金|費\s*用|入場料)\s*[:：]\s*(.+)$")
# 「11月18日」「18日」「2026年11月18日」「11/18」
DATE_TOKEN = re.compile(r"(?:(\d{4})年)?(?:(\d{1,2})月)?(\d{1,2})日|(\d{1,2})/(\d{1,2})")
RANGE_SEPARATOR = re.compile(r"[~〜ー－\-]|から")


def infer_year(month: int, day: int, posted: dt.date) -> dt.date | None:
    """投稿日の30日前以降で最も近い年を選ぶ（告知は開催前に出る）"""
    for year in (posted.year, posted.year + 1):
        try:
            candidate = dt.date(year, month, day)
        except ValueError:
            return None
        if candidate >= posted - dt.timedelta(days=30):
            return candidate
    return None


def parse_dates(line: str, posted: dt.date) -> list[tuple[dt.date, dt.date]] | None:
    """日時行から開催日を読む。2日付の間に「～」があれば期間、それ以外は個別日"""
    tokens: list[tuple[dt.date, re.Match]] = []
    month = None
    for match in DATE_TOKEN.finditer(line):
        if match.group(4):
            month, day, year = int(match.group(4)), int(match.group(5)), None
        else:
            year = int(match.group(1)) if match.group(1) else None
            month = int(match.group(2)) if match.group(2) else month
            day = int(match.group(3))
        if month is None or not (1 <= month <= 12):
            return None
        date = None
        if year:
            try:
                date = dt.date(year, month, day)
            except ValueError:
                date = None
        else:
            date = infer_year(month, day, posted)
        if date is None:
            return None
        tokens.append((date, match))
    if not tokens:
        return None
    if len(tokens) == 2:
        between = line[tokens[0][1].end():tokens[1][1].start()]
        if RANGE_SEPARATOR.search(between) and tokens[1][0] > tokens[0][0]:
            return [(tokens[0][0], tokens[1][0])]
    return [(date, date) for date, _ in tokens]


class TakarazukaKominkan:
    name = "takarazuka_kominkan"
    meta = {"name": SOURCE_NAME, "url": SITE_URL, "license": LICENSE,
            "note": "中央・東・西公民館の催し情報を毎日取得しています。日時は本文の記載から読み取っています。"}

    def __init__(self, resolver, pages: int = 2):
        self.resolver = resolver
        self.pages = pages
        self.skipped = 0

    def collect(self, now: dt.datetime, days_ahead: int) -> list[dict]:
        today, last_day = now.date(), now.date() + dt.timedelta(days=days_ahead)
        events: list[dict] = []
        for post_type, hall in HALLS.items():
            for page in range(1, self.pages + 1):
                posts = fetch_json(API.format(type=post_type, page=page))
                for post in posts:
                    events.extend(self._events(post, hall, now, today, last_day))
                if len(posts) < 50:
                    break
        return events

    def _events(self, post: dict, hall: str, now, today, last_day) -> list[dict]:
        title = nfkc(html_to_text(post["title"]["rendered"])).strip()
        text = html_to_text(post["content"]["rendered"])
        posted = dt.date.fromisoformat(post["date"][:10])
        if posted < today - dt.timedelta(days=240) or any(w in title for w in ("終了しました", "中止", "募集")):
            return []

        lines = text.splitlines()
        date_line = next((m.group(1) for line in lines if (m := LABEL_DATE.match(line))), None)
        spans = parse_dates(date_line, posted) if date_line else None
        if not spans:
            self.skipped += 1
            return []
        spans = [(s, e) for s, e in spans if e >= today and s <= last_day]
        if not spans:
            return []

        place_line = next((m.group(1) for line in lines if (m := LABEL_PLACE.match(line))), None)
        venue = self.resolver.match_known(place_line)
        if venue is None:
            # 「料理室」など館内の部屋名だけのときは、その公民館の位置を使う
            venue = self.resolver.known_venue(hall)
            if place_line:
                venue.name = f"{hall} {self.resolver.short_name(place_line)}".strip()

        price_line = next((m.group(1) for line in lines if (m := LABEL_PRICE.match(line))), None)
        price = price_line[:30] if price_line else None
        is_free = None if price is None else ("無料" in price or price.strip() in {"0円", "なし"})

        times = find_time_range(date_line)
        categories = merge_categories(keyword_categories(title), ["community"])
        updated = dt.datetime.fromisoformat(post["modified"]).replace(tzinfo=now.tzinfo)
        recurrence = f"全{len(spans)}回" if len(spans) > 1 else None
        return [build_event(
            url=post["link"], title=title, start_date=start, end_date=end, times=times, venue=venue,
            categories=categories, price=price, is_free=is_free, organizer=f"宝塚市立{hall}",
            source_name=SOURCE_NAME, source_url=SITE_URL, license=LICENSE,
            confidence=0.85, fetched_at=now, updated_at=updated, recurrence=recurrence,
        ) for start, end in spans]
