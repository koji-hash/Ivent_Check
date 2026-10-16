"""周辺イベント収集バッチ。

    python3 collector/collect.py --output docs/events.json

各ソースからイベントを取得 → 共通スキーマに正規化 → 検証・重複統合 → events.json を出力する。
AI は使わない。1日1回の実行を想定（GitHub Actions）。
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import math
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

FEED_VERSION = 1
GEOCODE_SOURCES = [
    {"name": "国土地理院 住所検索API", "url": "https://msearch.gsi.go.jp/address-search/AddressSearch",
     "license": "国土地理院", "note": "住所から緯度経度への変換に使用しています。"},
    {"name": "OpenStreetMap", "url": "https://www.openstreetmap.org/copyright",
     "license": "© OpenStreetMap contributors (ODbL)", "note": "施設名から位置を求める際に使用しています。"},
]
REGISTRY_DIR = HERE / "registry"
# 毎日の実行を地方ごとに並列化する単位（GitHub Actions の matrix）
REGIONS = {
    "hokkaido_tohoku": ["北海道", "青森県", "岩手県", "宮城県", "秋田県", "山形県", "福島県"],
    "kanto": ["茨城県", "栃木県", "群馬県", "埼玉県", "千葉県", "東京都", "神奈川県"],
    "chubu": ["新潟県", "富山県", "石川県", "福井県", "山梨県", "長野県", "岐阜県", "静岡県", "愛知県"],
    "kinki": ["三重県", "滋賀県", "京都府", "大阪府", "兵庫県", "奈良県", "和歌山県"],
    "chugoku_shikoku": ["鳥取県", "島根県", "岡山県", "広島県", "山口県", "徳島県", "香川県", "愛媛県", "高知県"],
    "kyushu_okinawa": ["福岡県", "佐賀県", "長崎県", "熊本県", "大分県", "宮崎県", "鹿児島県", "沖縄県"],
}
# 宝塚市の会場コード → venues.json の既知施設
TAKARAZUKA_PLACES = {
    "1": "宝塚市役所", "3": "フレミラ宝塚", "5": "スポーツセンター", "6": "ベガ・ホール",
    "7": "ソリオホール", "8": "宝塚文化創造館", "9": "中央公民館", "10": "男女共同参画センター",
}


def read_detected(directory: Path) -> list[dict]:
    """detect_cms.py が作った登録表（registry/detected_*.csv）をすべて読む"""
    rows: list[dict] = []
    for path in sorted(directory.glob("detected_*.csv")):
        with path.open() as f:
            rows += list(csv.DictReader(line for line in f if not line.startswith("#")))
    return rows


def build_sources(resolver: VenueResolver, cache_dir: Path, registry_dir: Path = REGISTRY_DIR,
                  prefs: list[str] | None = None) -> tuple[list, list[PageCache]]:
    """登録表から取得元を作る。個別の取得処理がある市町村（神戸市）はそちらを使う。prefs で都道府県を絞る"""
    kobe_cache = PageCache(cache_dir / "kobe_pages.json")
    list_cache = PageCache(cache_dir / "list_calendar_pages.json")
    detail_cache = PageCache(cache_dir / "detail_pages.json")
    sources: list = [Kobe(resolver, kobe_cache), TakarazukaKominkan(resolver)] if not prefs or "兵庫県" in prefs else []
    custom = {"神戸市"}

    for row in read_detected(registry_dir):
        if prefs and row["pref"] not in prefs:
            continue
        city = City(row["name"], row["pref"])
        base, method = row["base_url"], row["method"]
        if row["name"] in custom or method in ("", "unknown"):
            continue
        if method == "event_js":
            takarazuka = row["name"] == "宝塚市"
            sources.append(CityEventJs(CityEventJsConfig(
                city, base, row["feed"], place_defaults=TAKARAZUKA_PLACES if takarazuka else {},
                skip_outer=takarazuka), resolver, detail_cache))
        elif method == "calendar_json":
            sources.append(SmartCalendar(city, base, resolver, detail_cache))
        elif method == "list_calendar":
            sources.append(ListCalendar(city, base, resolver, list_cache))
    return sources, [kobe_cache, list_cache, detail_cache]


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


TILE_SIZE = 0.25  # 度（緯度方向で約28km）


def tile_key(latitude: float, longitude: float, size: float = TILE_SIZE) -> str:
    return f"{math.floor(latitude / size)}_{math.floor(longitude / size)}"


def write_tiles(events: list[dict], sources: list[dict], generated_at: str, directory: Path) -> int:
    """地域ごとのファイル（feed/tiles/*.json）と一覧（feed/index.json）を書き出す。

    アプリは index.json を見て、検索範囲に重なり、かつ hash が変わったファイルだけを取りに行く。
    """
    tiles: dict[str, list[dict]] = {}
    for event in events:
        tiles.setdefault(tile_key(event["latitude"], event["longitude"]), []).append(event)
    tile_dir = directory / "tiles"
    tile_dir.mkdir(parents=True, exist_ok=True)
    for old in tile_dir.glob("*.json"):
        if old.stem not in tiles:
            old.unlink()
    index = {}
    for key, items in sorted(tiles.items()):
        body = json.dumps(items, ensure_ascii=False, separators=(",", ":"))
        (tile_dir / f"{key}.json").write_text(body)
        index[key] = {"count": len(items), "hash": hashlib.sha1(body.encode()).hexdigest()[:12]}
    (directory / "index.json").write_text(json.dumps({
        "version": FEED_VERSION, "generatedAt": generated_at, "tileSize": TILE_SIZE,
        "sources": sources, "tiles": index,
    }, ensure_ascii=False, indent=1) + "\n")
    return len(index)


def seed_caches(cache_dir: Path, geocode_cache: Path) -> None:
    """Actions のキャッシュがまだ無いときは、リポジトリに入っているキャッシュから始める"""
    import shutil
    if not geocode_cache.exists() and geocode_cache != HERE / "geocode_cache.json":
        geocode_cache.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(HERE / "geocode_cache.json", geocode_cache)
    if cache_dir != HERE / "cache":
        cache_dir.mkdir(parents=True, exist_ok=True)
        for path in (HERE / "cache").glob("*.json"):
            if not (cache_dir / path.name).exists():
                shutil.copy(path, cache_dir / path.name)


def merge_parts(parts: list[Path], output: Path, tiles: str | None, now: dt.datetime, days_ahead: int) -> int:
    """地方ごとの出力（events.json と同じ形式）を1つにまとめ、地域ごとのファイルも書き出す"""
    events: list[dict] = []
    sources: list[dict] = []
    for part in parts:
        if not part.exists():
            print(f"  ! {part} がありません（その地方の収集が失敗した可能性）")
            continue
        feed = json.loads(part.read_text())
        events += feed["events"]
        sources += [s for s in feed["sources"] if s not in sources]
    events = sorted(dedupe(validate(events, now, days_ahead)), key=lambda e: (e["startAt"], e["title"]))
    if not events:
        print("イベントが0件のため出力しません")
        return 1
    feed = {"version": FEED_VERSION, "generatedAt": iso(now), "sources": sources, "events": events}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(feed, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"まとめ: {len(events)}件 → {output}")
    if tiles:
        print(f"地域ごとのファイル: {write_tiles(events, sources, feed['generatedAt'], Path(tiles))}個 → {tiles}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default=str(HERE.parent / "docs" / "events.json"))
    parser.add_argument("--days-ahead", type=int, default=60)
    parser.add_argument("--tiles", help="地域ごとのファイルの出力先（例: docs/feed）")
    parser.add_argument("--region", choices=sorted(REGIONS), help="この地方の都道府県だけ収集する")
    parser.add_argument("--cache-dir", type=Path, default=HERE / "cache")
    parser.add_argument("--geocode-cache", type=Path, default=HERE / "geocode_cache.json")
    parser.add_argument("--merge", nargs="+", type=Path, help="地方ごとの出力をまとめるだけ（収集しない）")
    parser.add_argument("--only", help="一部のソースだけ実行（名前の一部をカンマ区切り。例: kobe,川西市）")
    args = parser.parse_args()

    now = dt.datetime.now(JST).replace(microsecond=0)
    if args.merge:
        return merge_parts(args.merge, Path(args.output), args.tiles, now, args.days_ahead)
    seed_caches(args.cache_dir, args.geocode_cache)
    geocoder = Geocoder(args.geocode_cache)
    resolver = VenueResolver(HERE / "venues.json", geocoder)
    sources, caches = build_sources(resolver, args.cache_dir, prefs=REGIONS[args.region] if args.region else None)
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
    if args.tiles:
        count = write_tiles(events, feed["sources"], feed["generatedAt"], Path(args.tiles))
        print(f"地域ごとのファイル: {count}個 → {args.tiles}")

    approximate = sum(1 for e in events if e["confidence"] < 0.7)
    print(f"出力: {output} {len(events)}件（位置がおおよそ: {approximate}件）")
    print(f"会場の解決: {resolver.stats} / 位置検索の新規問い合わせ: {geocoder.live_requests}回"
          f"（上限で翌日以降に回した分: {geocoder.skipped}回） / "
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
