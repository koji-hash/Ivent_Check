"""おでかけKOBE（神戸市イベントサイト）。

公開サイトマップに載っているイベントページを読み、ページに埋め込まれた表示用データ（__NUXT_DATA__）から
名称・日付・会場・座標・料金・ジャンルを取り出す。解析結果は PageCache に保存し、
新しいページと開催が近いページだけを取りに行く（初回のみ件数が多い）。
"""
from __future__ import annotations

import datetime as dt
import json
import re

from common import (JST, build_event, clean_title, fetch, find_time_range, is_outing, keyword_categories,
                    merge_categories, nfkc)
from geocode import City, Venue

SITE = "https://event.city.kobe.lg.jp/"
SITEMAP = SITE + "sitemap.xml"
CITY = City("神戸市", "兵庫県")
# 神戸市の範囲（これを外れる座標は登録ミスとみなし、会場名から位置を求め直す）
BOUNDS = (34.55, 34.92, 134.95, 135.35)

GENRES = {
    "festival": "festival", "event": "festival", "sightseeing": "festival", "music": "music", "concert": "music",
    "art": "art", "exhibition": "art", "culture": "art", "theater": "art", "movie": "art",
    "sports": "sports", "childrearing": "kids", "kids": "kids", "children": "kids", "food": "food", "gourmet": "food",
    "market": "market", "learning": "community", "meetingSeminar": "community", "health": "community",
    "welfare": "community", "nature": "community", "environment": "community",
}


def decode_nuxt(html: str):
    """Nuxt の devalue 形式（配列の参照）を普通の dict/list に戻す"""
    m = re.search(r'<script[^>]*id="__NUXT_DATA__"[^>]*>(.*?)</script>', html, re.S)
    if not m:
        return None
    raw = json.loads(m.group(1))

    def revive(index, depth=0):
        if depth > 60:
            return None
        value = raw[index]
        if isinstance(value, list):
            if value and isinstance(value[0], str) and value[0] in ("ShallowReactive", "Reactive", "Ref", "ShallowRef"):
                return revive(value[1], depth + 1)
            if value and value[0] == "Date":
                return value[1]
            if value and value[0] in ("Set", "Map", "null"):
                return [revive(v, depth + 1) for v in value[1:]] if value[0] != "null" else None
            return [revive(v, depth + 1) if isinstance(v, int) else v for v in value]
        if isinstance(value, dict):
            return {k: revive(v, depth + 1) if isinstance(v, int) else v for k, v in value.items()}
        return value

    return revive(0)


def jst_date(value: str) -> str:
    """UTC の日時文字列を日本時間の日付にする"""
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(JST).date().isoformat()


def parse_page(html: str) -> dict | None:
    root = decode_nuxt(html)
    if not root:
        return None
    data = next(iter((root.get("data") or {}).values()), None)
    if not isinstance(data, dict) or data.get("status") != "published":
        return None
    entry = data.get("entryData") or {}
    base, event = entry.get("base") or {}, entry.get("event") or {}
    start = base.get("startDate") or base.get("startDateTime")
    if not base.get("name") or not start:
        return None
    coords = event.get("coordinates") or {}
    return {
        "title": base["name"],
        "start": jst_date(start),
        "end": jst_date(base.get("endDate") or start),
        "time": " ".join(filter(None, [event.get("time"), event.get("scheduleAdditionalInfo")]))[:200],
        "location": event.get("location") or "",
        "lat": coords.get("latitude"),
        "lon": coords.get("longitude"),
        "charge": event.get("charge"),
        "chargeAmount": event.get("chargeAmount") or "",
        "genre": event.get("genre") or [],
        "websiteUrl": base.get("websiteUrl") or "",
    }


class Kobe:
    name = "kobe"
    source_name = "おでかけKOBE（神戸市イベントサイト）"
    license = "神戸市（再利用条件の明示なし）。名称・日時・会場などの事実情報とリンクのみ掲載"
    meta = {"name": source_name, "url": SITE, "license": license,
            "note": "神戸市の公式イベントサイトに掲載されたイベントを毎日取得しています。"}

    def __init__(self, resolver, cache, max_fetch: int = 1200):
        self.resolver = resolver
        self.cache = cache
        self.max_fetch = max_fetch
        self.excluded = 0

    def collect(self, now: dt.datetime, days_ahead: int) -> list[dict]:
        today, last_day = now.date(), now.date() + dt.timedelta(days=days_ahead)
        urls = re.findall(r"<loc>(https://event\.city\.kobe\.lg\.jp/event/[^<]+)</loc>", fetch(SITEMAP))
        self.cache.retain(set(urls))
        budget = self.max_fetch
        for url in urls:
            record = self.cache.get(url)
            if record is not None:
                start = dt.date.fromisoformat(record["start"])
                end = dt.date.fromisoformat(record["end"])
                if end < today:
                    continue
                # 開催が近いものは中止・変更を拾うため3日ごとに取り直す
                max_age = 3 if (start - today).days <= 7 else 30
            else:
                max_age = 30
            if self.cache.is_fresh(url, now, max_age) or budget <= 0:
                continue
            budget -= 1
            try:
                self.cache.put(url, parse_page(fetch(url)), now)
            except Exception as error:
                print(f"  ! {url}: {error}")

        events: list[dict] = []
        for url in urls:
            record = self.cache.get(url)
            if not record:
                continue
            title = clean_title(record["title"])
            start, end = dt.date.fromisoformat(record["start"]), dt.date.fromisoformat(record["end"])
            if end < today or start > last_day or (end - start).days > 120:
                continue
            if not is_outing(title):
                self.excluded += 1
                continue
            venue = self._venue(record)
            times = find_time_range(record["time"]) if record["time"] and start == end else None
            charge = record.get("charge")
            is_free = True if charge == "free" else (False if charge in ("paid", "charge") else None)
            price = "無料" if is_free else (nfkc(record["chargeAmount"])[:30] or None)
            categories = merge_categories(keyword_categories(title),
                                          [GENRES[g] for g in record["genre"] if g in GENRES])
            events.append(build_event(
                url=url, title=title, start_date=start, end_date=end, times=times, venue=venue,
                categories=categories, price=price, is_free=is_free, organizer="神戸市",
                source_name=self.source_name, source_url=SITE, license=self.license,
                confidence=1.0, fetched_at=now, area="神戸市",
            ))
        return events

    def _venue(self, record: dict) -> Venue:
        lat, lon = record.get("lat"), record.get("lon")
        name = self.resolver.short_name(record["location"]) or "神戸市内"
        if isinstance(lat, (int, float)) and isinstance(lon, (int, float)) \
                and BOUNDS[0] <= lat <= BOUNDS[1] and BOUNDS[2] <= lon <= BOUNDS[3]:
            return Venue(name=name, address=None, latitude=lat, longitude=lon)
        return self.resolver.resolve(record["location"], CITY)
