"""市区町村サイトのイベントカレンダー方式を自動判定し、登録表（CSV）を作る。

    python3 collector/detect_cms.py collector/registry/municipalities_hyogo_osaka.csv \
        --output collector/registry/detected_hyogo_osaka.csv

既存の取得処理が対応している方式を、決まった URL があるかどうかで判定する:
- event_js       … event_calendar.html が読み込む JS データ（sources/city_event_js.py）
- calendar_json  … calendar.json（sources/smart_calendar.py）
- list_calendar  … event/calendar/list_calendar.html（sources/list_calendar.py）
まだ取得処理の無い方式も「候補」として判定し、対応の優先順位（人口カバー率）を決めるのに使う:
- calendar_php   … /calendar/index.php に日付・場所・時刻の一覧（岸和田・高槻など）
- event_php      … /event2/event_list.php など PHP のイベント一覧（枚方・東大阪など）
どれにも当たらない場合は、トップページからイベント・カレンダーらしいリンクを記録するだけにする。
サイトごとに別スレッドで並行して調べる（同じホストへの間隔は common.fetch が1秒以上に保つ）。

各サイトには robots.txt を確認したうえで数回だけアクセスする（同じホストへは1秒に1回まで）。
"""
from __future__ import annotations

import argparse
import concurrent.futures
import csv
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.robotparser
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from common import USER_AGENT, fetch  # noqa: E402

FIELDS = ["code", "pref", "name", "population", "method", "base_url", "feed", "note"]


def read_registry(path: Path) -> list[dict]:
    with path.open() as f:
        return list(csv.DictReader(line for line in f if not line.startswith("#")))


def try_fetch(url: str) -> str | None:
    try:
        return fetch(url, timeout=20)
    except (urllib.error.URLError, TimeoutError, ConnectionError, ValueError):
        return None


class Site:
    def __init__(self, website: str):
        parts = urllib.parse.urlparse(website)
        self.root = f"https://{parts.netloc}/"
        self.robots = urllib.robotparser.RobotFileParser()
        try:
            self.robots.parse((try_fetch(self.root + "robots.txt") or "").splitlines())
        except Exception:
            self.robots.parse([])

    def allowed(self, url: str) -> bool:
        return self.robots.can_fetch(USER_AGENT, url)

    def get(self, path: str) -> str | None:
        url = urllib.parse.urljoin(self.root, path)
        return try_fetch(url) if self.allowed(url) else None


def detect_event_js(site: Site) -> tuple[str, str] | None:
    page = site.get("event_calendar.html")
    if not page:
        return None
    m = re.search(r"event_data_files\.push\(['\"]\.?/?([^'\"]+)['\"]\)", page)
    candidates = [m.group(1)] if m else []
    candidates += [c for c in ("city_event.js", "event_data.js", "event.js") if c not in candidates]
    for feed in candidates:
        data = site.get(feed)
        if data and re.search(r"\bevents\s*:\s*\[", data):
            return "event_js", feed
    return None


def detect_calendar_json(site: Site) -> tuple[str, str] | None:
    data = site.get("calendar.json")
    if not data:
        return None
    try:
        items = json.loads(data)
    except ValueError:
        return None
    if isinstance(items, list) and items and isinstance(items[0], dict) and "date_list" in items[0]:
        return "calendar_json", "calendar.json"
    return None


def detect_list_calendar(site: Site) -> tuple[str, str] | None:
    page = site.get("event/calendar/list_calendar.html")
    if page and 'id="calendarlist"' in page:
        return "list_calendar", "event/calendar/list_calendar.html"
    return None


def detect_calendar_php(site: Site) -> tuple[str, str] | None:
    page = site.get("calendar/index.php") or site.get("calendar/")
    if page and re.search(r"icon_list_place|calendar_detail|common-calendar-event", page):
        return "calendar_php", "calendar/index.php"
    return None


def detect_event_php(site: Site) -> tuple[str, str] | None:
    for path in ("event2/event_list.php", "event2d/event_list.php", "event2/event_calendar.php"):
        page = site.get(path)
        if page and re.search(r"event_detail|event_list|ev=", page):
            return "event_php", path
    return None


def candidate_links(site: Site) -> str:
    top = site.get("") or ""
    links = re.findall(r'href="([^"]*(?:event|calendar|ibento|kanko|moyooshi)[^"]*)"', top, re.I)
    unique = list(dict.fromkeys(urllib.parse.urljoin(site.root, link) for link in links))
    return " ".join(unique[:5])


def detect(row: dict) -> dict:
    result = {key: row.get(key, "") for key in ("code", "pref", "name", "population")}
    result.update(base_url="", method="", feed="", note="")
    if not row.get("website"):
        result["method"] = "no_site"
        return result
    site = Site(row["website"])
    result["base_url"] = site.root
    for detector in (detect_event_js, detect_calendar_json, detect_list_calendar, detect_calendar_php, detect_event_php):
        if found := detector(site):
            result["method"], result["feed"] = found
            return result
    result["method"] = "unknown"
    result["note"] = candidate_links(site)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("registry", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--only", help="市町村名の一部（カンマ区切り）")
    parser.add_argument("--pref", help="都道府県名（カンマ区切り）")
    parser.add_argument("--workers", type=int, default=12)
    args = parser.parse_args()

    rows = read_registry(args.registry)
    if args.only:
        rows = [r for r in rows if any(k in r["name"] for k in args.only.split(","))]
    if args.pref:
        rows = [r for r in rows if r["pref"] in args.pref.split(",")]
    results = []

    def safe_detect(row: dict) -> dict:
        try:
            return detect(row)
        except Exception as error:  # 1つのサイトの失敗で全体を止めない
            return {**{k: row.get(k, "") for k in ("code", "pref", "name", "population")},
                    "base_url": row.get("website", ""), "method": "error", "feed": "", "note": repr(error)[:120]}

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        for result in pool.map(safe_detect, rows):
            print(f"{result['pref']} {result['name']}: {result['method']} {result['feed']}", flush=True)
            results.append(result)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="") as f:
        f.write("# detect_cms.py で自動生成。method を手で直した場合は note に理由を書く\n")
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(results)

    total = sum(int(r["population"] or 0) for r in results)
    supported = {"event_js", "calendar_json", "list_calendar"}
    by_method: dict[str, list[dict]] = {}
    for r in results:
        by_method.setdefault(r["method"], []).append(r)
    for method, items in sorted(by_method.items(), key=lambda kv: -sum(int(r["population"] or 0) for r in kv[1])):
        pop = sum(int(r["population"] or 0) for r in items)
        mark = "対応済み" if method in supported else "未対応"
        print(f"  {method:14s} {len(items):5d} 市区町村  人口 {pop / total:6.1%}  ({mark})" if total else "")
    covered = sum(int(r["population"] or 0) for r in results if r["method"] in supported)
    print(f"既存の取得処理で取れる見込み: 人口カバー率 {covered / total:.1%}" if total else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
