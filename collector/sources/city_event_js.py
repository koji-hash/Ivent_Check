"""イベントカレンダーの JS データ（`var event_data = { events: [...] }` 形式）。

宝塚市・川西市・尼崎市・吹田市などが同じ CMS を使っており、カレンダー画面が読み込むこのデータをそのまま使う。
- 日付: opendays / kikandays / regularweek
- 時刻: times（「午前10時00分から正午まで」）。無い市は説明文から1種類だけ読めた場合に使う
- 会場: place2（自由記述。「…[施設名]」や括弧内の住所を含むことが多い）
"""
from __future__ import annotations

import datetime as dt
import json
import re
import urllib.parse
from dataclasses import dataclass, field

from common import (build_event, categories_from_labels, clean_title, consecutive_runs, fetch, find_single_price,
                    find_time_range, is_outing, keyword_categories, merge_categories, nfkc,
                    venue_from_title)
from geocode import City
from sources.detail import DetailFetcher

WEEKDAYS = {"1": "日", "2": "月", "3": "火", "4": "水", "5": "木", "6": "金", "7": "土"}


@dataclass
class CityEventJsConfig:
    city: City
    base_url: str
    feed: str                       # 例: city_event.js / event_data.js / event.js
    calendar_page: str = "event_calendar.html"
    place_defaults: dict[str, str] = field(default_factory=dict)   # 会場コード → 既知施設名
    skip_outer: bool = False


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


def date_spans(item: dict) -> tuple[list[tuple[dt.date, dt.date]], str | None]:
    if item.get("kikandays"):
        return [(parse_date(k["from"]), parse_date(k["to"])) for k in item["kikandays"]], None
    days = [parse_date(d) for d in item.get("opendays", [])]
    if item.get("regularweek"):
        label = "・".join(WEEKDAYS.get(w, "") for w in item["regularweek"])
        return [(d, d) for d in days], f"毎週{label}曜日"
    runs = consecutive_runs(days)
    return runs, (f"全{len(runs)}回" if len(runs) > 1 else None)


class CityEventJs:
    def __init__(self, config: CityEventJsConfig, resolver, detail_cache=None):
        self.config = config
        self.resolver = resolver
        self.details = DetailFetcher(detail_cache, 150) if detail_cache is not None else None
        self.name = f"event_js:{config.city.name}"
        self.source_name = f"{config.city.name}ホームページ イベントカレンダー"
        self.calendar_url = config.base_url + config.calendar_page
        self.license = f"{config.city.name}ホームページ（再利用条件の明示なし）。名称・日時・会場などの事実情報とリンクのみ掲載"
        self.meta = {"name": self.source_name, "url": self.calendar_url, "license": self.license,
                     "note": f"{config.city.name}が公開しているイベントカレンダーのデータを毎日取得しています。"}
        self.excluded = 0

    def collect(self, now: dt.datetime, days_ahead: int) -> list[dict]:
        config = self.config
        feed = parse_feed(fetch(config.base_url + config.feed))
        categories_map = feed.get("categories", {})
        places = feed.get("places", {})
        today, last_day = now.date(), now.date() + dt.timedelta(days=days_ahead)
        events: list[dict] = []

        for item in feed["events"]:
            title = clean_title(item.get("eventtitle", ""))
            labels = [categories_map.get(c, "") for c in item.get("category", [])]
            if not title or (config.skip_outer and item.get("outer")) or not is_outing(title, labels):
                self.excluded += 1
                continue

            spans, recurrence = date_spans(item)
            spans = [(s, e) for s, e in spans if e >= today and s <= last_day]
            if not spans:
                continue

            url = urllib.parse.urljoin(config.base_url, item.get("url", ""))
            description = nfkc(item.get("description", ""))
            times_text = " ".join(dict.fromkeys(item.get("times") or []))
            times = find_time_range(times_text) if times_text else find_time_range(description)
            place_code = item.get("place")
            place_text = item.get("place2")
            if not place_text and self.details and place_code not in config.place_defaults:
                # 一覧に会場が無いときは詳細ページの「場所」欄を読む
                detail = self.details.get(url, now, spans[0][0], urllib.parse.urlparse(config.base_url).netloc)
                place_text = detail.get("place")
                if times is None and detail.get("time"):
                    times = find_time_range(detail["time"])
            venue = self.resolver.resolve(place_text or venue_from_title(title) or places.get(place_code), config.city,
                                          default=config.place_defaults.get(place_code))
            categories = merge_categories(keyword_categories(title), categories_from_labels(labels))
            expense = item.get("expense")
            is_free = {"3": True, "1": False, "2": False}.get(expense)
            price = "無料" if is_free else (find_single_price(description) or {"1": "有料", "2": "一部有料"}.get(expense))

            for start, end in spans:
                events.append(build_event(
                    url=url, title=title, start_date=start, end_date=end, times=times, venue=venue,
                    categories=categories, price=price, is_free=is_free, organizer=config.city.name,
                    source_name=self.source_name, source_url=self.calendar_url, license=self.license,
                    confidence=1.0 if times_text or not times else 0.9, fetched_at=now, recurrence=recurrence,
                    area=config.city.name,
                ))
        return events
