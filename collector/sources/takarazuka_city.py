"""宝塚市ホームページのイベントカレンダー（city_event.js）。

カレンダー画面が読み込んでいる構造化データをそのまま使う。AI 不要。
- 日付は opendays / kikandays / regularweek で表現される（開始時刻は無い）
- 会場は place コード＋自由記述 place2
"""
from __future__ import annotations

import datetime as dt
import json
import re
import urllib.parse

from common import (consecutive_runs, build_event, fetch, find_single_price, find_time_range,
                    keyword_categories, merge_categories, nfkc)

BASE_URL = "https://www.city.takarazuka.hyogo.jp/"
FEED_URL = BASE_URL + "city_event.js"
CALENDAR_URL = BASE_URL + "event_calendar.html"

SOURCE_NAME = "宝塚市ホームページ イベントカレンダー"
LICENSE = "宝塚市ホームページ（再利用条件の明示なし）。名称・日時・会場などの事実情報とリンクのみ掲載"

# 市のカテゴリコード → アプリのカテゴリ
CATEGORY_MAP = {"4": "art", "1": "community", "2": "kids", "6": "other", "10": "sports", "25": "other"}
# 会場コード → venues.json の既知施設（自由記述が無いときに使う）
PLACE_MAP = {
    "1": "宝塚市役所", "3": "フレミラ宝塚", "5": "スポーツセンター", "6": "ベガ・ホール",
    "7": "ソリオホール", "8": "宝塚文化創造館", "9": "中央公民館", "10": "男女共同参画センター",
}
WEEKDAYS = {"1": "日", "2": "月", "3": "火", "4": "水", "5": "木", "6": "金", "7": "土"}


def parse_feed(js: str) -> dict:
    """`var event_data = { events: [...], categories: {...}, ... }` から各キーを取り出す"""
    decoder = json.JSONDecoder()
    result: dict = {}
    for match in re.finditer(r"\b(events|categories|places|targets|expenses):\s*([\[{])", js):
        if match.group(1) not in result:
            result[match.group(1)], _ = decoder.raw_decode(js, match.start(2))
    return result


def parse_date(text: str) -> dt.date:
    return dt.date(*map(int, text.split("/")))


class TakarazukaCity:
    name = "takarazuka_city"
    meta = {"name": SOURCE_NAME, "url": CALENDAR_URL, "license": LICENSE,
            "note": "宝塚市が公開しているイベントカレンダーのデータを毎日取得しています。開始時刻は掲載ページでご確認ください。"}

    def __init__(self, resolver):
        self.resolver = resolver

    def collect(self, now: dt.datetime, days_ahead: int) -> list[dict]:
        feed = parse_feed(fetch(FEED_URL))
        places = feed.get("places", {})
        today, last_day = now.date(), now.date() + dt.timedelta(days=days_ahead)
        events: list[dict] = []

        for item in feed["events"]:
            title = nfkc(item.get("eventtitle", "")).strip()
            # 公民館サイトの催しは別ソースで詳しく取るので除外。作品・参加者の募集は「行くイベント」ではない
            if not title or item.get("outer") or "募集" in title or "中止" in title:
                continue

            spans, recurrence = self._date_spans(item)
            spans = [(s, e) for s, e in spans if e >= today and s <= last_day]
            if not spans:
                continue

            url = urllib.parse.urljoin(BASE_URL, item.get("url", ""))
            description = nfkc(item.get("description", ""))
            times = find_time_range(description)
            place_code = item.get("place")
            venue = self.resolver.resolve(item.get("place2") or places.get(place_code),
                                          default=PLACE_MAP.get(place_code))
            categories = merge_categories(keyword_categories(title),
                                          [CATEGORY_MAP.get(c, "other") for c in item.get("category", [])])
            expense = item.get("expense")
            is_free = {"3": True, "1": False, "2": False}.get(expense)
            price = "無料" if is_free else (find_single_price(description) or {"1": "有料", "2": "一部有料"}.get(expense))

            for start, end in spans:
                events.append(build_event(
                    url=url, title=title, start_date=start, end_date=end, times=times, venue=venue,
                    categories=categories, price=price, is_free=is_free, organizer="宝塚市",
                    source_name=SOURCE_NAME, source_url=CALENDAR_URL, license=LICENSE,
                    # 構造化データなので高め。時刻を本文から推定した場合だけ少し下げる
                    confidence=0.9 if times else 1.0, fetched_at=now, recurrence=recurrence,
                ))
        return events

    @staticmethod
    def _date_spans(item: dict) -> tuple[list[tuple[dt.date, dt.date]], str | None]:
        if item.get("kikandays"):
            return [(parse_date(k["from"]), parse_date(k["to"])) for k in item["kikandays"]], None
        days = [parse_date(d) for d in item.get("opendays", [])]
        if item.get("regularweek"):
            label = "・".join(WEEKDAYS.get(w, "") for w in item["regularweek"])
            return [(d, d) for d in days], f"毎週{label}曜日"
        runs = consecutive_runs(days)
        return runs, (f"全{len(runs)}回" if len(runs) > 1 else None)
