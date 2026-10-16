"""ネットワーク不要の単体テスト:  python3 -m unittest discover collector"""
import datetime as dt
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import choose_icon, consecutive_runs, find_time_range  # noqa: E402
from geocode import VenueResolver  # noqa: E402
from sources.takarazuka_city import TakarazukaCity, parse_feed  # noqa: E402
from sources.takarazuka_kominkan import LABEL_DATE, parse_dates  # noqa: E402


class TimeRangeTests(unittest.TestCase):
    def test_formats(self):
        self.assertEqual(find_time_range("10:00~20:20"), (dt.time(10), dt.time(20, 20)))
        self.assertEqual(find_time_range("13時半~16時"), (dt.time(13, 30), dt.time(16)))
        self.assertEqual(find_time_range("午後1時30分~3時30分"), (dt.time(13, 30), dt.time(15, 30)))
        self.assertEqual(find_time_range("１０：００～１２：００"), (dt.time(10), dt.time(12)))

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
        spans, recurrence = TakarazukaCity._date_spans(feed["events"][0])
        self.assertEqual(spans, [(dt.date(2026, 10, 20), dt.date(2026, 10, 21)), (dt.date(2026, 10, 25),) * 2])
        self.assertEqual(recurrence, "全2回")

    def test_weekly(self):
        spans, recurrence = TakarazukaCity._date_spans({"opendays": ["2026/10/18"], "regularweek": ["1"]})
        self.assertEqual(recurrence, "毎週日曜日")


class MiscTests(unittest.TestCase):
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
