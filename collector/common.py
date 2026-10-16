"""収集バッチの共通処理（HTTP取得・テキスト整形・カテゴリ判定・イベント生成）。

標準ライブラリのみで動く。AI は使わない。
"""
from __future__ import annotations

import datetime as dt
import json
import re
import time
import unicodedata
import urllib.parse
import urllib.request
import uuid
from html import unescape

JST = dt.timezone(dt.timedelta(hours=9))
USER_AGENT = "ivent-check-collector/1.0 (daily low-frequency event collector; contact via repository)"

# 同じホストへ連続アクセスしないための待ち時間（秒）
_REQUEST_INTERVAL = 1.0
_last_request: dict[str, float] = {}


def fetch(url: str, timeout: int = 30) -> str:
    host = urllib.parse.urlparse(url).netloc
    wait = _REQUEST_INTERVAL - (time.monotonic() - _last_request.get(host, 0))
    if wait > 0:
        time.sleep(wait)
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Language": "ja"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read()
        charset = response.headers.get_content_charset() or "utf-8"
    _last_request[host] = time.monotonic()
    return body.decode(charset, errors="replace")


def fetch_json(url: str):
    return json.loads(fetch(url))


def nfkc(text: str) -> str:
    return unicodedata.normalize("NFKC", text)


def html_to_text(html: str) -> str:
    """HTML を行単位のプレーンテキストにする（全角英数は半角に正規化）"""
    html = re.sub(r"(?i)<br\s*/?>|</(p|div|li|tr|h\d)>", "\n", html)
    html = re.sub(r"<[^>]+>", "", html)
    text = nfkc(unescape(html)).replace(" ", " ")
    lines = (re.sub(r"[ \t　]+", " ", line).strip() for line in text.splitlines())
    return "\n".join(line for line in lines if line)


# 「10:00~13:00」のような時間帯
TIME_RANGE = re.compile(r"(\d{1,2}):(\d{2})\s*[~〜\-ー－]\s*(\d{1,2}):(\d{2})")


def find_time_range(text: str) -> tuple[dt.time, dt.time] | None:
    """時間帯が1種類だけ書かれている場合に限り返す（複数あると誤りやすいので使わない）"""
    text = nfkc(text)
    text = re.sub(r"(\d{1,2})時(\d{1,2})分", r"\1:\2", text)
    text = re.sub(r"(\d{1,2})時半", r"\1:30", text)
    text = re.sub(r"(\d{1,2})時(?!間)", r"\1:00", text)
    # 「午後1:30」→「13:30」
    text = re.sub(r"午後\s*(\d{1,2}):", lambda m: f"{int(m.group(1)) + 12 if int(m.group(1)) < 12 else m.group(1)}:", text)
    text = text.replace("午前", "")
    found = {m.groups() for m in TIME_RANGE.finditer(text)}
    if len(found) != 1:
        return None
    h1, m1, h2, m2 = map(int, found.pop())
    if h2 < h1 and h2 + 12 > h1:  # 「13:30~3:30」のように終了側の午後が省略された場合
        h2 += 12
    if not (0 <= h1 < 24 and 0 <= h2 < 24 and m1 < 60 and m2 < 60) or (h2, m2) <= (h1, m1):
        return None
    return dt.time(h1, m1), dt.time(h2, m2)


YEN = re.compile(r"(\d[\d,]*)\s*円")


def find_single_price(text: str) -> str | None:
    found = {m.group(1) for m in YEN.finditer(nfkc(text))}
    return f"{found.pop()}円" if len(found) == 1 else None


# アプリ側の EventCategory（festival, fireworks, market, music, art, sports, kids, food, community, other）
CATEGORY_KEYWORDS: list[tuple[str, tuple[str, ...]]] = [
    ("fireworks", ("花火",)),
    ("festival", ("まつり", "祭り", "祭", "フェスティバル", "フェスタ")),
    ("market", ("マルシェ", "朝市", "フリーマーケット", "フリマ", "バザー", "即売会")),
    ("music", ("コンサート", "演奏", "ライブ", "音楽", "合唱", "ジャズ", "吹奏楽", "ミュージック")),
    ("art", ("展示", "展覧", "作品展", "美術", "アート", "写真展", "ギャラリー", "上映", "映画", "落語", "演劇", "歌劇", "書道", "絵画")),
    ("sports", ("スポーツ", "ウォーキング", "体操", "ヨガ", "マラソン", "運動", "テニス", "卓球", "体力測定")),
    ("kids", ("子ども", "こども", "子供", "親子", "キッズ", "赤ちゃん", "乳幼児", "小学生", "幼児")),
    ("food", ("グルメ", "料理", "食べ", "パン", "カフェ", "コーヒー", "スイーツ", "お菓子")),
]


def keyword_categories(text: str) -> list[str]:
    return [category for category, words in CATEGORY_KEYWORDS if any(w in text for w in words)]


def merge_categories(*groups: list[str]) -> list[str]:
    result: list[str] = []
    for group in groups:
        for category in group:
            if category not in result:
                result.append(category)
    if len(result) > 1 and "other" in result:
        result.remove("other")
    return result or ["other"]


# アプリ側に用意したアイコン（EventIcon）。上から順に最初に当たったものを使う
ICON_KEYWORDS: list[tuple[str, tuple[str, ...]]] = [
    ("fireworks", ("花火",)),
    ("festival", ("まつり", "祭り", "祭", "フェスティバル", "フェスタ", "盆踊り")),
    ("market", ("マルシェ", "朝市", "フリーマーケット", "フリマ", "バザー", "即売会", "物産")),
    ("food", ("グルメ", "料理", "食べ", "パン", "カフェ", "コーヒー", "スイーツ", "お菓子", "ランチ", "食堂")),
    ("music", ("コンサート", "演奏", "ライブ", "音楽", "合唱", "ジャズ", "吹奏楽", "ミュージック", "ピアノ")),
    ("theater", ("落語", "演劇", "歌劇", "映画", "上映", "公演", "舞台", "朗読")),
    ("exhibition", ("展示", "展覧", "作品展", "美術", "アート", "写真展", "パネル展", "市展", "ギャラリー")),
    ("craft", ("工作", "手づくり", "手作り", "ワークショップ", "フェルト", "絵手紙", "書道", "クラフト")),
    ("library", ("図書館", "絵本", "おはなし会", "読み聞かせ", "読書")),
    ("kids", ("子ども", "こども", "子供", "親子", "キッズ", "赤ちゃん", "乳幼児", "小学生", "幼児")),
    ("walk", ("ウォーキング", "散策", "ハイキング", "自然観察", "まち歩き")),
    ("sports", ("スポーツ", "体操", "ヨガ", "マラソン", "運動", "テニス", "卓球", "体力測定", "囲碁", "将棋")),
    ("health", ("健康", "フレイル", "介護", "福祉", "医療", "認知症", "予防", "検診")),
    ("consultation", ("相談",)),
    ("lecture", ("講座", "講演", "セミナー", "教室", "学習会", "研修", "説明会")),
    ("community", ("交流", "地域", "ボランティア", "清掃", "防災", "文化祭", "人権")),
]
CATEGORY_ICON = {
    "festival": "festival", "fireworks": "fireworks", "market": "market", "music": "music", "art": "exhibition",
    "sports": "sports", "kids": "kids", "food": "food", "community": "community", "other": "other",
}


def choose_icon(title: str, categories: list[str]) -> str:
    for icon, words in ICON_KEYWORDS:
        if any(w in title for w in words):
            return icon
    return CATEGORY_ICON.get(categories[0], "other") if categories else "other"


def event_id(url: str, start: dt.date) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{url}#{start.isoformat()}"))


def iso(value: dt.datetime) -> str:
    return value.isoformat(timespec="seconds")


def build_event(
    *,
    url: str,
    title: str,
    start_date: dt.date,
    end_date: dt.date,
    times: tuple[dt.time, dt.time] | None,
    venue,
    categories: list[str],
    price: str | None,
    is_free: bool | None,
    organizer: str | None,
    source_name: str,
    source_url: str,
    license: str,
    confidence: float,
    fetched_at: dt.datetime,
    updated_at: dt.datetime | None = None,
    recurrence: str | None = None,
    image_url: str | None = None,
) -> dict:
    """アプリの Event（要件書 5.3 共通スキーマ）と同じ形の dict を作る。

    end_date は最終日（その日を含む）。時刻が無ければ終日イベントにする。
    """
    if times:
        start_at = dt.datetime.combine(start_date, times[0], JST)
        end_at = dt.datetime.combine(end_date, times[1], JST)
    else:
        start_at = dt.datetime.combine(start_date, dt.time(0, 0), JST)
        end_at = dt.datetime.combine(end_date + dt.timedelta(days=1), dt.time(0, 0), JST)
    return {
        "id": event_id(url, start_date),
        "title": title,
        "description": None,  # 本文は転載しない（出典リンクへ誘導する）
        "category": categories,
        "icon": choose_icon(title, categories),
        "startAt": iso(start_at),
        "endAt": iso(end_at),
        "isAllDay": times is None,
        "recurrence": recurrence,
        "venueName": venue.name,
        "address": venue.address,
        "latitude": round(venue.latitude, 6),
        "longitude": round(venue.longitude, 6),
        "price": price,
        "isFree": is_free,
        "organizer": organizer,
        "officialUrl": url,
        "imageUrl": image_url,  # 再利用が許諾されたソースの画像だけ渡される
        "sourceName": source_name,
        "sourceUrl": source_url,
        "license": license,
        "confidence": round(confidence * (0.6 if venue.approximate else 1.0), 2),
        "fetchedAt": iso(fetched_at),
        "updatedAt": iso(updated_at or fetched_at),
    }


def consecutive_runs(dates: list[dt.date]) -> list[tuple[dt.date, dt.date]]:
    """連続した日付をまとめる。例: [1,2,3,5] -> [(1,3),(5,5)]"""
    runs: list[tuple[dt.date, dt.date]] = []
    for day in sorted(set(dates)):
        if runs and day - runs[-1][1] == dt.timedelta(days=1):
            runs[-1] = (runs[-1][0], day)
        else:
            runs.append((day, day))
    return runs
