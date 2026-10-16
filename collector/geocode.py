"""住所・施設名 → 緯度経度。

1. 国土地理院 住所検索API（住所文字列向け・無料）
2. OpenStreetMap Nominatim（施設名向け。利用規約に従い 1秒1回以下・結果は永続キャッシュ）

一度引いた結果は geocode_cache.json に保存し、同じ文字列では二度と問い合わせない。
すべての解決は「どの市町村のイベントか（City）」の範囲で行い、別の市の同名施設を拾わないようにする。
"""
from __future__ import annotations

import json
import re
import urllib.parse
from dataclasses import dataclass
from pathlib import Path

from common import fetch_json, nfkc

GSI_URL = "https://msearch.gsi.go.jp/address-search/AddressSearch?q="
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"

DASHES = re.compile(r"(?<=\d)\s*[‐‑‒–—―−－ーｰ~〜]\s*(?=\d)")
# 「東大物町1-1」「泉町2丁目29番1号」「火打1-12-16」のような番地付きの地名
ADDRESS = re.compile(r"([^\s\d()\[\]、。:,;/・「」]{1,24}?\d{1,4}(?:(?:丁目|番地|番|号|-|の)\d{0,4}){0,4})")
NOT_ADDRESS = re.compile(r"(?:\d+(?:階|F|号室|番線|分|人|名|回|歳|年|月|日|時)|^[第約])")


@dataclass(frozen=True)
class City:
    name: str        # 例: 川西市
    pref: str        # 例: 兵庫県

    @property
    def full(self) -> str:
        return self.pref + self.name


@dataclass
class Venue:
    name: str
    address: str | None
    latitude: float
    longitude: float
    approximate: bool = False


class Geocoder:
    def __init__(self, cache_path: Path):
        self.cache_path = cache_path
        self.cache: dict[str, dict | None] = json.loads(cache_path.read_text()) if cache_path.exists() else {}
        self.live_requests = 0

    def save(self) -> None:
        self.cache_path.write_text(json.dumps(self.cache, ensure_ascii=False, indent=1, sort_keys=True) + "\n")

    def address(self, address: str, city: City | None = None, allow_coarse: bool = False) -> tuple[float, float] | None:
        """国土地理院。結果が同じ市内で、市名だけの大ざっぱな一致でないときに採用する"""
        key = f"gsi:{address}"
        if key not in self.cache:
            self.live_requests += 1
            try:
                results = fetch_json(GSI_URL + urllib.parse.quote(address))
            except Exception as error:  # 通信失敗はキャッシュしない
                print(f"  ! GSI failed: {address}: {error}")
                return None
            hit = results[0] if results else None
            self.cache[key] = None if hit is None else {
                "lon": hit["geometry"]["coordinates"][0],
                "lat": hit["geometry"]["coordinates"][1],
                "title": hit["properties"]["title"],
            }
        hit = self.cache[key]
        if hit is None:
            return None
        title = nfkc(hit["title"])
        expected = city.name if city else self._city_in(address)
        if expected and expected not in title:
            return None
        if not allow_coarse and (city and title in {city.full, city.name}):
            return None
        return hit["lat"], hit["lon"]

    def place(self, name: str, viewbox: tuple[float, float, float, float]) -> dict | None:
        """Nominatim。viewbox（西,北,東,南）の範囲内だけを対象にする"""
        key = f"osm:{name}@{','.join(f'{v:.2f}' for v in viewbox)}"
        if key not in self.cache:
            self.live_requests += 1
            query = urllib.parse.urlencode({
                "q": name, "format": "jsonv2", "limit": 1, "countrycodes": "jp",
                "viewbox": ",".join(map(str, viewbox)), "bounded": 1, "accept-language": "ja",
            })
            try:
                results = fetch_json(f"{NOMINATIM_URL}?{query}")
            except Exception as error:
                print(f"  ! Nominatim failed: {name}: {error}")
                return None
            self.cache[key] = None if not results else {
                "lat": float(results[0]["lat"]), "lon": float(results[0]["lon"]),
                "title": results[0].get("display_name", ""),
            }
        return self.cache[key]

    @staticmethod
    def _city_in(text: str) -> str | None:
        m = re.search(r"(?:[都道府県])?([^都道府県\s\d]{1,5}?[市町村])", nfkc(text))
        return m.group(1) if m else None


class VenueResolver:
    """会場の自由記述を Venue にする（市町村ごと）。

    優先順: 既知施設 → [施設名] 表記 → 文中の住所 → 施設名で検索 → 市の代表地点（おおよその位置）
    """

    def __init__(self, venues_path: Path, geocoder: Geocoder):
        config = json.loads(venues_path.read_text())
        self.geocoder = geocoder
        self.venues = config["venues"]
        for entry in self.venues:
            entry.setdefault("city", config.get("default_city", "宝塚市"))
        self.known = sorted(self.venues, key=lambda v: -max(len(k) for k in v["keywords"]))
        self.stats = {"known": 0, "address": 0, "search": 0, "approximate": 0}
        self._centers: dict[City, tuple[float, float]] = {}

    # MARK: 既知施設

    def known_venue(self, name: str, city: City, approximate: bool = False) -> Venue:
        entry = next(v for v in self.venues if v["name"] == name and v["city"] == city.name)
        lat, lon = self._coordinates(entry, city)
        return Venue(name=entry["name"], address=entry.get("address"), latitude=lat, longitude=lon, approximate=approximate)

    def match_known(self, text: str | None, city: City) -> Venue | None:
        raw = nfkc(text or "").strip()
        for entry in self.known:
            if entry["city"] == city.name and any(keyword in raw for keyword in entry["keywords"]):
                self.stats["known"] += 1
                lat, lon = self._coordinates(entry, city)
                return Venue(name=self.short_name(raw) or entry["name"], address=entry.get("address"),
                             latitude=lat, longitude=lon)
        return None

    # MARK: 解決

    def resolve(self, text: str | None, city: City, default: str | None = None) -> Venue:
        raw = DASHES.sub("-", nfkc(text or "")).strip()
        label = self.short_name(raw)
        bracket = re.search(r"\[([^\]]{2,30})\]\s*$", raw)  # 「…[川西公民館]」の形式
        facility = bracket.group(1).strip() if bracket else label

        if venue := self.match_known(raw, city):
            return venue

        for address in self.address_candidates(raw)[:3]:
            query = address if re.match(r"^(?:\S{2,3}[都道府県])", address) else (
                city.pref + address if re.match(r"^\S{1,5}?[市町村]", address) else city.full + address)
            if coordinates := self.geocoder.address(query, None if self._other_city(address, city) else city):
                self.stats["address"] += 1
                return Venue(name=facility or label or address, address=query,
                             latitude=coordinates[0], longitude=coordinates[1])

        names = [n for n in dict.fromkeys((facility, label)) if n and len(n) >= 3]
        for name in names:
            queries = [name] if name.startswith(city.name) else [name, f"{city.name}{name}", f"{city.name}立{name}"]
            for query in queries:
                hit = self.geocoder.place(query, self.viewbox(city))
                if hit and self._osm_name_matches(name, hit):
                    self.stats["search"] += 1
                    return Venue(name=name, address=None, latitude=hit["lat"], longitude=hit["lon"])

        self.stats["approximate"] += 1
        if default and any(v["name"] == default and v["city"] == city.name for v in self.venues):
            venue = self.known_venue(default, city, approximate=True)
        else:
            lat, lon = self.city_center(city)
            venue = Venue(name=city.name, address=None, latitude=lat, longitude=lon, approximate=True)
        venue.name = facility or label or venue.name
        venue.address = None
        return venue

    def city_center(self, city: City) -> tuple[float, float]:
        """市の代表地点（国土地理院の市名検索の結果。多くは市役所付近）"""
        if city not in self._centers:
            coordinates = self.geocoder.address(city.full, city, allow_coarse=True)
            if coordinates is None:
                raise RuntimeError(f"市の位置を取得できません: {city.full}")
            self._centers[city] = coordinates
        return self._centers[city]

    def viewbox(self, city: City, margin: float = 0.12) -> tuple[float, float, float, float]:
        lat, lon = self.city_center(city)
        return (round(lon - margin, 2), round(lat + margin, 2), round(lon + margin, 2), round(lat - margin, 2))

    @staticmethod
    def address_candidates(text: str) -> list[str]:
        text = DASHES.sub("-", nfkc(text))
        # 「所在地:」「住所:」の後ろと括弧の中を優先する
        parts = re.findall(r"(?:所在地|住所)\s*[:：]?\s*([^()\[\]、。]+)", text) + re.findall(r"[(（]([^()（）]+)[)）]", text) + [text]
        found: list[str] = []
        for part in parts:
            for m in ADDRESS.finditer(part):
                candidate = m.group(1).strip(" -")
                if NOT_ADDRESS.search(candidate) or not re.search(r"\d", candidate):
                    continue
                if candidate not in found:
                    found.append(candidate)
        return found

    @staticmethod
    def _other_city(address: str, city: City) -> bool:
        m = re.match(r"^(?:\S{2,3}[都道府県])?(\S{1,5}?[市町村])", address)
        return bool(m) and m.group(1) != city.name

    @staticmethod
    def _osm_name_matches(label: str, hit: dict) -> bool:
        """OSM の結果名（display_name の先頭）と会場名が対応しているときだけ採用する"""
        def core(text: str) -> str:
            return re.sub(r"^\S{1,5}?[市町村]立?|\s", "", nfkc(text))
        osm_name = core(hit.get("title", "").split(",")[0])
        name = core(label)
        return len(osm_name) >= 3 and (osm_name in name or name in osm_name)

    # 会場コードの分類名など、施設名ではない記述
    NOT_VENUE = re.compile(r"^(?:その他の施設|教育・文化・芸術|健康・保健|スポーツ|公民館|市内各所|各\S{0,8}|オンライン|未定|\d+月\d+日.*|\d+階)$")

    @staticmethod
    def short_name(text: str) -> str:
        """「宝塚市立中央公民館(阪急逆瀬川駅徒歩12分)」→「宝塚市立中央公民館」、「ことば蔵1階交流フロア」→「ことば蔵」"""
        text = re.sub(r"^\s*[【\[<][^】\]>]*[】\]>]", "", nfkc(text))  # 先頭の【開催場所】などを除く
        name = re.split(r"[(（※、。【\[<〔/]|住所|所在地| |\d+階|\d+F|地下\d", text, maxsplit=1)[0].strip(" :：「」")
        name = re.sub(r"[「」『』]", "", name)
        return "" if VenueResolver.NOT_VENUE.match(name) else name[:40]

    def _coordinates(self, entry: dict, city: City) -> tuple[float, float]:
        if "lat" in entry:
            return entry["lat"], entry["lon"]
        coordinates = self.geocoder.address(entry["address"], city) if entry.get("address") else None
        if coordinates is None:
            raise RuntimeError(f"既知施設の座標を取得できません: {entry['name']}")
        entry["lat"], entry["lon"] = coordinates
        return coordinates
