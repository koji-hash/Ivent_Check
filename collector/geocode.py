"""住所・施設名 → 緯度経度。

1. 国土地理院 住所検索API（住所文字列向け・無料）
2. OpenStreetMap Nominatim（施設名向け。利用規約に従い 1秒1回以下・結果は永続キャッシュ）

一度引いた結果は geocode_cache.json に保存し、同じ文字列では二度と問い合わせない。
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

    def address(self, address: str) -> tuple[float, float] | None:
        """国土地理院。結果の住所表記に必ず含まれるべき市名で検証する"""
        key = f"gsi:{address}"
        if key not in self.cache:
            self.live_requests += 1
            try:
                results = fetch_json(GSI_URL + urllib.parse.quote(address))
            except Exception as error:  # 通信失敗はキャッシュしない
                print(f"  ! GSI failed: {address}: {error}")
                return None
            hit = next((r for r in results if self._same_city(address, r["properties"]["title"])), None)
            self.cache[key] = None if hit is None else {
                "lon": hit["geometry"]["coordinates"][0],
                "lat": hit["geometry"]["coordinates"][1],
                "title": hit["properties"]["title"],
            }
        hit = self.cache[key]
        return None if hit is None else (hit["lat"], hit["lon"])

    def place(self, name: str, viewbox: tuple[float, float, float, float]) -> tuple[float, float] | None:
        """Nominatim。viewbox（西,北,東,南）の範囲内だけを対象にする"""
        key = f"osm:{name}"
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
        hit = self.cache[key]
        return None if hit is None else (hit["lat"], hit["lon"])

    @staticmethod
    def _same_city(query: str, title: str) -> bool:
        city = re.search(r"[^都道府県\s]{1,6}?[市町村]", nfkc(query).replace("兵庫県", ""))
        return city is None or city.group(0) in title


class VenueResolver:
    """会場の自由記述を Venue にする。

    優先順: 既知施設のキーワード → 文中の住所 → 施設名で検索 → 既定地点（おおよその位置）
    """

    ADDRESS = re.compile(r"((?:兵庫県)?宝塚市[^\s、。()（）※]*?\d+(?:[-−ー丁目番地号の]+\d+)*(?:番地?|号)?)")

    def __init__(self, venues_path: Path, geocoder: Geocoder):
        config = json.loads(venues_path.read_text())
        self.geocoder = geocoder
        self.viewbox = tuple(config["viewbox"])
        self.fallback_name = config["fallback"]
        self.known = sorted(config["venues"], key=lambda v: -max(len(k) for k in v["keywords"]))
        self.by_name = {v["name"]: v for v in config["venues"]}
        self.stats = {"known": 0, "address": 0, "search": 0, "approximate": 0}

    def known_venue(self, name: str, approximate: bool = False) -> Venue:
        entry = self.by_name[name]
        lat, lon = self._coordinates(entry)
        return Venue(name=entry["name"], address=entry.get("address"), latitude=lat, longitude=lon, approximate=approximate)

    def match_known(self, text: str | None) -> Venue | None:
        raw = nfkc(text or "").strip()
        for entry in self.known:
            if any(keyword in raw for keyword in entry["keywords"]):
                self.stats["known"] += 1
                lat, lon = self._coordinates(entry)
                return Venue(name=self.short_name(raw) or entry["name"], address=entry.get("address"),
                             latitude=lat, longitude=lon)
        return None

    def resolve(self, text: str | None, default: str | None = None) -> Venue:
        raw = nfkc(text or "").strip()
        label = self.short_name(raw)

        if venue := self.match_known(raw):
            return venue

        if match := self.ADDRESS.search(raw):
            address = match.group(1)
            if coordinates := self.geocoder.address(address):
                self.stats["address"] += 1
                return Venue(name=label or address, address=address, latitude=coordinates[0], longitude=coordinates[1])

        if label and len(label) >= 4:
            if (coordinates := self.geocoder.place(label, self.viewbox)) and self._osm_name_matches(label):
                self.stats["search"] += 1
                return Venue(name=label, address=None, latitude=coordinates[0], longitude=coordinates[1])

        self.stats["approximate"] += 1
        venue = self.known_venue(default or self.fallback_name, approximate=True)
        venue.name = label or venue.name
        venue.address = None
        return venue

    def _osm_name_matches(self, label: str) -> bool:
        """OSM の結果名（display_name の先頭）と会場名が対応しているときだけ採用する"""
        hit = self.geocoder.cache.get(f"osm:{label}") or {}
        osm_name = nfkc(hit.get("title", "").split(",")[0]).replace("宝塚市立", "").replace(" ", "")
        core = label.replace("宝塚市立", "").replace(" ", "")
        return bool(osm_name) and (osm_name in core or core in osm_name)

    @staticmethod
    def short_name(text: str) -> str:
        """「宝塚市立中央公民館(阪急逆瀬川駅徒歩12分)」→「宝塚市立中央公民館」"""
        text = re.sub(r"^\s*[【\[<][^】\]>]*[】\]>]", "", text)  # 先頭の【開催場所】などを除く
        name = re.split(r"[(（※、。【\[<]|住所|所在地| ", text, maxsplit=1)[0].strip(" :：")
        return name[:40]

    def _coordinates(self, entry: dict) -> tuple[float, float]:
        if "lat" in entry:
            return entry["lat"], entry["lon"]
        coordinates = self.geocoder.address(entry["address"]) if entry.get("address") else None
        if coordinates is None and entry.get("osm"):
            coordinates = self.geocoder.place(entry["osm"], self.viewbox)
        if coordinates is None:
            raise RuntimeError(f"既知施設の座標を取得できません: {entry['name']}")
        entry["lat"], entry["lon"] = coordinates
        return coordinates
