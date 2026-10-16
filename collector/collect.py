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
from geocode import Geocoder, VenueResolver  # noqa: E402
from sources.takarazuka_city import TakarazukaCity  # noqa: E402
from sources.takarazuka_kominkan import TakarazukaKominkan  # noqa: E402

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
        return title, event["startAt"][:10]

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
    args = parser.parse_args()

    now = dt.datetime.now(JST).replace(microsecond=0)
    geocoder = Geocoder(HERE / "geocode_cache.json")
    resolver = VenueResolver(HERE / "venues.json", geocoder)
    sources = [TakarazukaCity(resolver), TakarazukaKominkan(resolver)]

    collected: list[dict] = []
    used_sources: list[dict] = []
    for source in sources:
        try:
            events = source.collect(now, args.days_ahead)
        except Exception as error:  # 1つのソースが落ちても他は続ける
            print(f"[{source.name}] 失敗: {error!r}")
            continue
        print(f"[{source.name}] {len(events)}件")
        collected.extend(events)
        used_sources.append(source.meta)

    events = sorted(dedupe(validate(collected, now, args.days_ahead)), key=lambda e: (e["startAt"], e["title"]))
    geocoder.save()
    if not events:
        print("イベントが0件のため出力しません（前回の events.json を残します）")
        return 1

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    feed = {"version": FEED_VERSION, "generatedAt": iso(now), "sources": used_sources + GEOCODE_SOURCES, "events": events}
    output.write_text(json.dumps(feed, ensure_ascii=False, indent=1) + "\n")

    approximate = sum(1 for e in events if e["confidence"] < 0.7)
    print(f"出力: {output} {len(events)}件（位置がおおよそ: {approximate}件）")
    print(f"会場の解決: {resolver.stats} / 位置検索の新規問い合わせ: {geocoder.live_requests}回")
    for source in sources:
        if getattr(source, "skipped", 0):
            print(f"[{source.name}] 日時を読めずに除外: {source.skipped}件")
    return 0


if __name__ == "__main__":
    sys.exit(main())
