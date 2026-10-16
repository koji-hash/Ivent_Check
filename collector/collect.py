"""周辺イベント収集バッチ。

    python3 collector/collect.py --output docs/events.json

各ソースからイベントを取得 → 共通スキーマに正規化 → 検証・重複統合 → events.json を出力する。
AI は使わない。1日1回の実行を想定（GitHub Actions）。
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from common import JST, iso, nfkc  # noqa: E402
from geocode import City, Geocoder, VenueResolver  # noqa: E402
from pagecache import PageCache  # noqa: E402
from sources.city_event_js import CityEventJs, CityEventJsConfig  # noqa: E402
from sources.kobe import Kobe  # noqa: E402
from sources.list_calendar import ListCalendar  # noqa: E402
from sources.smart_calendar import SmartCalendar  # noqa: E402
from sources.takarazuka_kominkan import TakarazukaKominkan  # noqa: E402

HYOGO, OSAKA = "兵庫県", "大阪府"
# 宝塚市の会場コード → venues.json の既知施設
TAKARAZUKA_PLACES = {
    "1": "宝塚市役所", "3": "フレミラ宝塚", "5": "スポーツセンター", "6": "ベガ・ホール",
    "7": "ソリオホール", "8": "宝塚文化創造館", "9": "中央公民館", "10": "男女共同参画センター",
}


def build_sources(resolver: VenueResolver, cache_dir: Path) -> tuple[list, list[PageCache]]:
    """収集対象。宝塚市を中心に、おおむね30km圏の市町"""
    kobe_cache = PageCache(cache_dir / "kobe_pages.json")
    list_cache = PageCache(cache_dir / "list_calendar_pages.json")
    detail_cache = PageCache(cache_dir / "detail_pages.json")
    sources = [
        CityEventJs(CityEventJsConfig(City("宝塚市", HYOGO), "https://www.city.takarazuka.hyogo.jp/", "city_event.js",
                                      place_defaults=TAKARAZUKA_PLACES, skip_outer=True), resolver),
        TakarazukaKominkan(resolver),
        CityEventJs(CityEventJsConfig(City("川西市", HYOGO), "https://www.city.kawanishi.hyogo.jp/", "event_data.js"), resolver, detail_cache),
        CityEventJs(CityEventJsConfig(City("尼崎市", HYOGO), "https://www.city.amagasaki.hyogo.jp/", "event_data.js"), resolver, detail_cache),
        CityEventJs(CityEventJsConfig(City("吹田市", OSAKA), "https://www.city.suita.osaka.jp/", "event.js"), resolver, detail_cache),
        SmartCalendar(City("伊丹市", HYOGO), "https://www.city.itami.lg.jp/", resolver, detail_cache),
        SmartCalendar(City("三田市", HYOGO), "https://www.city.sanda.lg.jp/", resolver, detail_cache),
        SmartCalendar(City("池田市", OSAKA), "https://www.city.ikeda.osaka.jp/", resolver, detail_cache),
        SmartCalendar(City("猪名川町", HYOGO), "https://www.town.inagawa.lg.jp/", resolver, detail_cache),
        ListCalendar(City("西宮市", HYOGO), "https://www.nishi.or.jp/", resolver, list_cache),
        ListCalendar(City("豊中市", OSAKA), "https://www.city.toyonaka.osaka.jp/", resolver, list_cache),
        Kobe(resolver, kobe_cache),
    ]
    return sources, [kobe_cache, list_cache, detail_cache]

FEED_VERSION = 1
GEOCODE_SOURCES = [
    {"name": "国土地理院 住所検索API", "url": "https://msearch.gsi.go.jp/address-search/AddressSearch",
     "license": "国土地理院", "note": "住所から緯度経度への変換に使用しています。"},
    {"name": "OpenStreetMap", "url": "https://www.openstreetmap.org/copyright",
     "license": "© OpenStreetMap contributors (ODbL)", "note": "施設名から位置を求める際に使用しています。"},
]


def validate(events: list[dict], now: dt.datetime, days_ahead: int) -> list[dict]:
    """日付が読めない・おかしいものを除く（AI抽出ではないが念のため）"""
    last = now + dt.timedelta(days=days_ahead + 1)
    valid = []
    for event in events:
        start, end = dt.datetime.fromisoformat(event["startAt"]), dt.datetime.fromisoformat(event["endAt"])
        if end <= start or end <= now or start > last or (end - start).days > 120:
            continue
        if not (-90 <= event["latitude"] <= 90 and -180 <= event["longitude"] <= 180):
            continue
        valid.append(event)
    return valid


def dedupe(events: list[dict]) -> list[dict]:
    """同じ名称・同じ開始日のものは1件にまとめる（時刻があり信頼度の高い方を残す）"""
    def key(event):
        title = re.sub(r"[\s【】「」『』()（）!！~〜・]", "", nfkc(event["title"]))
        return title, event["startAt"][:10], round(event["latitude"], 2), round(event["longitude"], 2)

    best: dict = {}
    for event in events:
        k = key(event)
        current = best.get(k)
        score = (not event["isAllDay"], event["confidence"])
        if current is None or score > (not current["isAllDay"], current["confidence"]):
            best[k] = event
    return list(best.values())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default=str(HERE.parent / "docs" / "events.json"))
    parser.add_argument("--days-ahead", type=int, default=60)
    parser.add_argument("--only", help="一部のソースだけ実行（名前の一部をカンマ区切り。例: kobe,川西市）")
    args = parser.parse_args()

    now = dt.datetime.now(JST).replace(microsecond=0)
    geocoder = Geocoder(HERE / "geocode_cache.json")
    resolver = VenueResolver(HERE / "venues.json", geocoder)
    sources, caches = build_sources(resolver, HERE / "cache")
    if args.only:
        sources = [source for source in sources if any(key in source.name for key in args.only.split(","))]

    collected: list[dict] = []
    used_sources: list[dict] = []
    for source in sources:
        try:
            events = source.collect(now, args.days_ahead)
        except Exception as error:  # 1つのソースが落ちても他は続ける
            print(f"[{source.name}] 失敗: {error!r}")
            continue
        finally:
            geocoder.save()
            for cache in caches:
                cache.save()
        print(f"[{source.name}] {len(events)}件（対象外として除外: {getattr(source, 'excluded', 0)}件）")
        collected.extend(events)
        used_sources.append(source.meta)

    events = sorted(dedupe(validate(collected, now, args.days_ahead)), key=lambda e: (e["startAt"], e["title"]))
    if not events:
        print("イベントが0件のため出力しません（前回の events.json を残します）")
        return 1

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    feed = {"version": FEED_VERSION, "generatedAt": iso(now), "sources": used_sources + GEOCODE_SOURCES, "events": events}
    output.write_text(json.dumps(feed, ensure_ascii=False, indent=1) + "\n")

    approximate = sum(1 for e in events if e["confidence"] < 0.7)
    print(f"出力: {output} {len(events)}件（位置がおおよそ: {approximate}件）")
    print(f"会場の解決: {resolver.stats} / 位置検索の新規問い合わせ: {geocoder.live_requests}回 / "
          f"詳細ページの取得: {sum(c.fetched for c in caches)}件")
    by_area: dict[str, int] = {}
    for event in events:
        by_area[event.get("area") or "?"] = by_area.get(event.get("area") or "?", 0) + 1
    print("市町村別:", dict(sorted(by_area.items(), key=lambda kv: -kv[1])))
    for source in sources:
        if getattr(source, "skipped", 0):
            print(f"[{source.name}] 日時を読めずに除外: {source.skipped}件")
    return 0


if __name__ == "__main__":
    sys.exit(main())
