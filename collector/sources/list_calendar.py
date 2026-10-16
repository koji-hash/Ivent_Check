"""月別イベントカレンダー（`/event/calendar/list_calendar.html`、`list_calendarYYYYMM.html`）。

西宮市・豊中市などが使う CMS。カレンダーには日付ごとに「種別アイコン＋イベント名＋リンク」が並ぶ。
会場と時刻は詳細ページの「場所」「日時」欄から読み、結果を PageCache に保存して毎日は取りに行かない。
"""
from __future__ import annotations

import datetime as dt
import re
import urllib.parse
from collections import defaultdict

from common import (build_event, categories_from_labels, clean_title, consecutive_runs, fetch, find_single_price,
                    find_time_range, html_to_text, is_outing, keyword_categories, merge_categories, nfkc,
                    venue_from_title)
from geocode import City
from sources.detail import DetailFetcher, labeled_value, parse_detail  # noqa: F401  (テストから利用)

# 西宮: <td class="date" id="day1"><span class="calendar_day">1日 </span>…　豊中: <td class="event"><span class="calendar_day">1日<a id="1">…
ROW = re.compile(r'<td class="[^"]*"[^>]*>\s*(?:<span class="calendar_day">)?\s*(\d{1,2})日.*?</td>\s*<td class="einfo">(.*?)</td>', re.S)
PARAGRAPH = re.compile(r"<p>(.*?)</p>", re.S)
# 種別アイコン＋イベント名リンク（＋豊中は会場アイコン＋会場リンク）
ENTRY = re.compile(r'<img[^>]*alt="([^"]*)"[^>]*>\s*<a href="([^"]+)">(.*?)</a>(?:.*?place\.png[^>]*>\s*<a [^>]*>(.*?)</a>)?', re.S)


def parse_month(html: str) -> list[tuple[int, str, str, str, str | None]]:
    """(日, 種別, リンク, イベント名, 会場) の一覧"""
    entries = []
    for day, cell in ROW.findall(html):
        for paragraph in PARAGRAPH.findall(cell):
            if m := ENTRY.search(paragraph):
                label, href, name, place = m.groups()
                entries.append((int(day), label, href, name, place))
    return entries
class ListCalendar:
    def __init__(self, city: City, base_url: str, resolver, cache, months: int = 3, max_fetch: int = 250):
        self.city = city
        self.base_url = base_url
        self.resolver = resolver
        self.cache = cache
        self.months = months
        self.max_fetch = max_fetch
        self.name = f"list_calendar:{city.name}"
        self.source_name = f"{city.name}ホームページ イベントカレンダー"
        self.calendar_url = base_url + "event/calendar/list_calendar.html"
        self.license = f"{city.name}ホームページ（再利用条件の明示なし）。名称・日時・会場などの事実情報とリンクのみ掲載"
        self.meta = {"name": self.source_name, "url": self.calendar_url, "license": self.license,
                     "note": f"{city.name}のイベントカレンダーを毎日取得し、会場は各ページの記載から読み取っています。"}
        self.excluded = 0

    def _month_urls(self, now: dt.datetime) -> list[tuple[int, int, str]]:
        urls = []
        year, month = now.year, now.month
        for i in range(self.months):
            suffix = "" if i == 0 else f"{year}{month:02d}"
            urls.append((year, month, f"{self.base_url}event/calendar/list_calendar{suffix}.html"))
            month += 1
            if month > 12:
                year, month = year + 1, 1
        return urls

    def collect(self, now: dt.datetime, days_ahead: int) -> list[dict]:
        today, last_day = now.date(), now.date() + dt.timedelta(days=days_ahead)
        days: dict[str, set[dt.date]] = defaultdict(set)
        info: dict[str, tuple[str, str, str | None]] = {}
        for year, month, url in self._month_urls(now):
            try:
                html = fetch(url)
            except Exception as error:
                print(f"  ! {url}: {error}")
                continue
            for day, label, href, name, place in parse_month(html):
                date = dt.date(year, month, day)
                if not (today <= date <= last_day):
                    continue
                link = urllib.parse.urljoin(self.base_url, href)
                days[link].add(date)
                info[link] = (clean_title(html_to_text(name)), nfkc(label), html_to_text(place) if place else None)

        events: list[dict] = []
        details = DetailFetcher(self.cache, self.max_fetch)
        host = urllib.parse.urlparse(self.base_url).netloc
        for link, dates in days.items():
            title, label, listed_place = info[link]
            if not is_outing(title, [label]):
                self.excluded += 1
                continue
            # 一覧に会場が載っていれば詳細ページは取りに行かない（時刻のためには取りに行く価値があるが件数を抑える）
            detail = details.get(link, now, min(dates), host) if not listed_place else {}

            venue = self.resolver.resolve(listed_place or detail.get("place") or venue_from_title(title), self.city)
            times = find_time_range(detail["time"]) if detail.get("time") else None
            price = detail.get("price")
            is_free = None if not price else ("無料" in price)
            if price and not is_free:
                price = find_single_price(price) or price[:30]
            categories = merge_categories(keyword_categories(title), categories_from_labels([label]))
            runs = consecutive_runs(sorted(dates))
            recurrence = f"全{len(runs)}回" if len(runs) > 1 else None
            for start, end in runs[:8]:
                events.append(build_event(
                    url=link, title=title, start_date=start, end_date=end, times=times, venue=venue,
                    categories=categories, price=price if price else None, is_free=is_free,
                    organizer=self.city.name, source_name=self.source_name, source_url=self.calendar_url,
                    license=self.license, confidence=0.9 if detail else 0.8, fetched_at=now,
                    recurrence=recurrence, area=self.city.name,
                ))
        return events
