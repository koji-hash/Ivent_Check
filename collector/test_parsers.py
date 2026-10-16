"""ネットワーク不要の単体テスト:  python3 -m unittest discover collector"""
import datetime as dt
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import choose_icon, clean_title, consecutive_runs, find_time_range, is_outing  # noqa: E402
from geocode import VenueResolver  # noqa: E402
from sources.city_event_js import date_spans, parse_feed  # noqa: E402
from sources.kobe import jst_date  # noqa: E402
from sources.list_calendar import labeled_value, parse_month  # noqa: E402
from sources.takarazuka_kominkan import LABEL_DATE, parse_dates  # noqa: E402


class TimeRangeTests(unittest.TestCase):
    def test_formats(self):
        self.assertEqual(find_time_range("10:00~20:20"), (dt.time(10), dt.time(20, 20)))
        self.assertEqual(find_time_range("13時半~16時"), (dt.time(13, 30), dt.time(16)))
        self.assertEqual(find_time_range("午後1時30分~3時30分"), (dt.time(13, 30), dt.time(15, 30)))
        self.assertEqual(find_time_range("１０：００～１２：００"), (dt.time(10), dt.time(12)))

    def test_japanese_phrases(self):
        self.assertEqual(find_time_range("午前10時00分から正午まで"), (dt.time(10), dt.time(12)))
        self.assertEqual(find_time_range("午後6時00分から午後9時00分まで"), (dt.time(18), dt.time(21)))

    def test_ambiguous_is_rejected(self):
        self.assertIsNone(find_time_range("午前の部10:30~12:00 午後の部14:00~15:30"))
        self.assertIsNone(find_time_range("16:00開演"))


class KominkanDateTests(unittest.TestCase):
    posted = dt.date(2026, 10, 3)

    def test_separate_days_inherit_month(self):
        self.assertEqual(parse_dates("11月18日(水) 20日(金) 10:00~13:00", self.posted),
                         [(dt.date(2026, 11, 18),) * 2, (dt.date(2026, 11, 20),) * 2])

    def test_range(self):
        self.assertEqual(parse_dates("6月14日(月)~7月4日(日)", dt.date(2026, 6, 1)),
                         [(dt.date(2026, 6, 14), dt.date(2026, 7, 4))])

    def test_year_rollover(self):
        self.assertEqual(parse_dates("1月15日(金)", dt.date(2026, 11, 20)), [(dt.date(2027, 1, 15),) * 2])

    def test_unreadable(self):
        self.assertIsNone(parse_dates("毎月第2水曜日", self.posted))
        self.assertIsNone(parse_dates("19月4日(金)", self.posted))

    def test_label_styles(self):
        for line in ["日時:11月28日(土)", "<日時>10月24日(土)", "【開催日時】2026年11月28日(土)", "◆日 時:2026年7月4日(土)", "開催日 2026年10月24日(土)"]:
            self.assertIsNotNone(LABEL_DATE.match(line), line)
        self.assertIsNone(LABEL_DATE.match("日時は後日お知らせします"))


class CityFeedTests(unittest.TestCase):
    def test_parse_feed_and_spans(self):
        js = 'var event_data = { events: [{"eventtitle":"a","opendays":["2026/10/20","2026/10/21","2026/10/25"]}], categories: {"4":"観光"}, };'
        feed = parse_feed(js)
        self.assertEqual(feed["categories"], {"4": "観光"})
        spans, recurrence = date_spans(feed["events"][0])
        self.assertEqual(spans, [(dt.date(2026, 10, 20), dt.date(2026, 10, 21)), (dt.date(2026, 10, 25),) * 2])
        self.assertEqual(recurrence, "全2回")

    def test_weekly(self):
        spans, recurrence = date_spans({"opendays": ["2026/10/18"], "regularweek": ["1"]})
        self.assertEqual(recurrence, "毎週日曜日")


class ListCalendarTests(unittest.TestCase):
    def test_nishinomiya_rows(self):
        html = ('<td class="date" id="day3"><span class="calendar_day">3日 </span>土曜日</td> <td class="einfo"><p>'
                '<img src="/i.png" alt="催し" /> <a href="/a/b.html">秋まつり</a></p></td></tr>')
        self.assertEqual(parse_month(html), [(3, "催し", "/a/b.html", "秋まつり", None)])

    def test_toyonaka_rows_with_place(self):
        html = ('<td class="sat"> <span class="calendar_day">3日<a id="3" name="3"></a></span> 土曜日</td> '
                '<td class="einfo"><p><img src="/images/cal_icon05.png" alt="スポーツ"/><a href="/x.html">ブレイキン</a>&nbsp;'
                '<img src="/images/place.png" alt="" /><a href="https://example/p.html">グリーンスポーツセンター</a></p>'
                '<ul><li></li></ul><p>募集期間:2026年9月3日</p></td>')
        self.assertEqual(parse_month(html), [(3, "スポーツ", "/x.html", "ブレイキン", "グリーンスポーツセンター")])

    def test_labeled_value(self):
        lines = ["日時", "11月3日 10時~15時", "場所:市民会館 大ホール"]
        self.assertEqual(labeled_value(lines, "日\\s*時"), "11月3日 10時~15時")
        self.assertEqual(labeled_value(lines, "場\\s*所"), "市民会館 大ホール")


class RegistryTests(unittest.TestCase):
    def test_sources_from_registry(self):
        import tempfile
        import collect
        from geocode import Geocoder, VenueResolver
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "detected_test.csv").write_text(
                "# test\ncode,pref,name,population,method,base_url,feed,note\n"
                "1,兵庫県,宝塚市,1,event_js,https://a.example/,city_event.js,\n"
                "2,兵庫県,伊丹市,1,calendar_json,https://b.example/,calendar.json,\n"
                "3,大阪府,豊中市,1,list_calendar,https://c.example/,event/calendar/list_calendar.html,\n"
                "4,兵庫県,神戸市,1,list_calendar,https://d.example/,x,\n"
                "5,兵庫県,どこか町,1,unknown,https://e.example/,,\n")
            resolver = VenueResolver(Path(collect.HERE) / "venues.json", Geocoder(tmp / "g.json"))
            sources, _ = collect.build_sources(resolver, tmp, registry_dir=tmp)
            names = [source.name for source in sources]
            self.assertEqual(names, ["kobe", "takarazuka_kominkan", "event_js:宝塚市",
                                     "calendar_json:伊丹市", "list_calendar:豊中市"])
            self.assertTrue(sources[2].config.skip_outer)


class TileTests(unittest.TestCase):
    def test_write_tiles(self):
        import json
        import tempfile
        import collect
        events = [{"latitude": 34.81, "longitude": 135.34, "title": "a"},
                  {"latitude": 34.82, "longitude": 135.36, "title": "b"},
                  {"latitude": 35.68, "longitude": 139.76, "title": "c"}]
        with tempfile.TemporaryDirectory() as tmp:
            count = collect.write_tiles(events, [], "2026-10-16T05:00:00+09:00", Path(tmp))
            index = json.loads((Path(tmp) / "index.json").read_text())
            self.assertEqual(count, 2)
            key = collect.tile_key(34.81, 135.34)
            self.assertEqual(index["tiles"][key]["count"], 2)
            self.assertEqual(len(json.loads((Path(tmp) / "tiles" / f"{key}.json").read_text())), 2)


class MiscTests(unittest.TestCase):
    def test_outing_filter(self):
        self.assertFalse(is_outing("第3回 景観審議会"))
        self.assertFalse(is_outing("弁護士相談"))
        self.assertTrue(is_outing("秋の植物観察会", ["催し"]))
        self.assertFalse(is_outing("オンライン講座", ["オンライン"]))

    def test_clean_title(self):
        self.assertEqual(clean_title("【10/17~受付開始】ピアノを弾こう"), "ピアノを弾こう")
        self.assertEqual(clean_title("【展覧会】川村摩那"), "【展覧会】川村摩那")

    def test_kobe_date_is_japan_time(self):
        self.assertEqual(jst_date("2026-12-15T15:00:00.000Z"), "2026-12-16")
        self.assertEqual(jst_date("2026-12-16T00:00:00.000Z"), "2026-12-16")

    def test_address_candidates(self):
        self.assertIn("東大物町1-1", VenueResolver.address_candidates("大物公園(東大物町1－1)"))
        self.assertIn("火打1-12-16", VenueResolver.address_candidates("川西公民館 集会室(火打1−12−16 キセラ川西プラザ福祉棟3階)[川西公民館]"))
        self.assertFalse(any("階" in c for c in VenueResolver.address_candidates("市民会館3階")))

    def test_runs(self):
        d = dt.date(2026, 10, 1)
        self.assertEqual(consecutive_runs([d, d + dt.timedelta(1), d + dt.timedelta(5)]),
                         [(d, d + dt.timedelta(1)), (d + dt.timedelta(5),) * 2])

    def test_icons(self):
        self.assertEqual(choose_icon("宝塚サマーライブ2026", ["music"]), "music")
        self.assertEqual(choose_icon("西公民館パン教室", ["community"]), "food")
        self.assertEqual(choose_icon("何かの集まり", ["kids"]), "kids")

    def test_short_name(self):
        self.assertEqual(VenueResolver.short_name("宝塚市立中央公民館(阪急逆瀬川駅徒歩12分)"), "宝塚市立中央公民館")
        self.assertEqual(VenueResolver.short_name("【開催場所】安倉児童館【申し込み】安倉児童館"), "安倉児童館")


if __name__ == "__main__":
    unittest.main()
