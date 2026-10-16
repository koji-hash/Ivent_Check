"""イベントカレンダーの `calendar.json`（伊丹市・三田市・池田市・猪名川町などが使う CMS）。

[{page_name, url, date_list: [[開始, 終了], ...], event: {event_place, event_type_name, ...}}]
時刻は含まれないため終日扱い。
"""
from __future__ import annotations

import datetime as dt
import urllib.parse

from common import (build_event, categories_from_labels, clean_title, fetch_json, find_time_range, is_outing,
                    keyword_categories, merge_categories, venue_from_title)
from geocode import City
from sources.detail import DetailFetcher


class SmartCalendar:
    def __init__(self, city: City, base_url: str, resolver, detail_cache=None):
        self.city = city
        self.details = DetailFetcher(detail_cache, 150) if detail_cache is not None else None
        self.base_url = base_url
        self.resolver = resolver
        self.name = f"calendar_json:{city.name}"
        self.source_name = f"{city.name}ホームページ イベントカレンダー"
        self.calendar_url = base_url + "calendar.html"
        self.license = f"{city.name}ホームページ（再利用条件の明示なし）。名称・日時・会場などの事実情報とリンクのみ掲載"
        self.meta = {"name": self.source_name, "url": self.calendar_url, "license": self.license,
                     "note": f"{city.name}が公開しているイベントカレンダーのデータを毎日取得しています。"}
        self.excluded = 0

    def collect(self, now: dt.datetime, days_ahead: int) -> list[dict]:
        today, last_day = now.date(), now.date() + dt.timedelta(days=days_ahead)
        events: list[dict] = []
        for item in fetch_json(self.base_url + "calendar.json"):
            title = clean_title(item.get("page_name", ""))
            detail = item.get("event") or {}
            labels = [detail.get("event_type_name") or ""]
            if not title or not is_outing(title, labels):
                self.excluded += 1
                continue
            spans = []
            for start, end in item.get("date_list", []):
                s, e = dt.date.fromisoformat(start[:10]), dt.date.fromisoformat(end[:10])
                if e >= today and s <= last_day:
                    spans.append((s, e))
            if not spans:
                continue
            # 毎日・毎週のように開催日が多いものは、直近の数回だけ載せる
            spans = spans[:8]
            place_text = detail.get("event_place")
            times = None
            url = item["url"].replace("http://", "https://")
            if self.details:
                # 会場が無いとき・時刻を知りたいときは詳細ページの「場所」「日時」欄を読む
                page = self.details.get(url, now, spans[0][0], urllib.parse.urlparse(self.base_url).netloc)
                place_text = place_text or page.get("place")
                if page.get("time") and len(spans) == 1:
                    times = find_time_range(page["time"])
            venue = self.resolver.resolve(place_text or venue_from_title(title), self.city)
            categories = merge_categories(keyword_categories(title), categories_from_labels(labels))
            recurrence = f"ほか{len(item['date_list']) - 1}日開催" if len(item.get("date_list", [])) > 1 else None
            for start, end in spans:
                events.append(build_event(
                    url=url, title=title, start_date=start, end_date=end,
                    times=times, venue=venue, categories=categories, price=None, is_free=None,
                    organizer=self.city.name, source_name=self.source_name, source_url=self.calendar_url,
                    license=self.license, confidence=1.0, fetched_at=now, recurrence=recurrence, area=self.city.name,
                ))
        return events
