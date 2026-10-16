# イベント収集バッチ

毎朝1回、公開されているイベント情報を集めて `docs/events.json` を作ります。
アプリはこの JSON を取得し、端末側で現在地からの距離と日付で絞り込みます。
サーバー・データベース・AI は使いません（Python 標準ライブラリのみ）。

## 取得元（宝塚市を中心におおむね30km圏・11市町）

| 方式 | 市町 | 日時 | 会場 |
|---|---|---|---|
| イベントカレンダーの JS データ（`city_event.js` / `event_data.js` / `event.js`） | 宝塚市・川西市・尼崎市・吹田市 | 日付＋時刻（`times` 欄、無ければ説明文から1種類だけ読めた場合） | 自由記述（括弧内の住所・`[施設名]`） |
| 宝塚市立公民館（WordPress REST API） | 宝塚市 | 本文の「日時：」行 | 3館の住所 |
| `calendar.json` | 伊丹市・三田市・池田市・猪名川町 | 日付のみ | `event_place`（施設名） |
| 月別カレンダー `list_calendar*.html` ＋ 詳細ページ | 西宮市・豊中市 | 日付＋詳細ページの「日時」 | 詳細ページの「場所」 |
| おでかけKOBE（公開サイトマップ＋各ページの表示用データ） | 神戸市 | 日付＋時刻欄 | 登録座標（神戸市内のときのみ）／会場名 |
| 国土地理院 住所検索API / OpenStreetMap | 会場の緯度経度 | | 結果は `geocode_cache.json` に保存し再問い合わせしない |

- 会議・審議会・相談会・募集・中止のお知らせなど「出かける催し」でないものは除外します（`common.is_outing`）。
- 詳細ページは `collector/cache/` に解析結果（事実情報のみ）を保存し、新しいページと開催が近いページだけを取り直します。
  初回は神戸市だけで約1,000ページを取得するため 20〜30 分かかります（2回目以降は数分）。
- どのサイトも再利用条件が明示されていないため、名称・日時・会場・料金などの事実情報とリンクのみを載せ、
  本文や画像は転載しません（アプリでは種類別に用意したアイコンを表示）。

## ローカルで実行

```bash
python3 collector/collect.py --output docs/events.json
python3 collector/collect.py --only kobe          # 一部のソースだけ試す
python3 -m unittest discover collector
```

## 公開手順（GitHub Pages）

1. GitHub に**公開**リポジトリを作り、このフォルダを push する（Actions の無料枠が実質無制限になる）
2. リポジトリの Settings → Pages → Source を **GitHub Actions** にする
3. Actions タブで `collect-events` を一度手動実行（Run workflow）する。
   初回は取得済みページのキャッシュが無い地方があるため時間がかかる（各地方の上限は5時間）
4. `https://<ユーザー名>.github.io/<リポジトリ名>/feed/index.json` が開けたら、
   アプリの `ivent_check-Info.plist` の `EventFeedURL` に `https://<ユーザー名>.github.io/<リポジトリ名>/feed/` を設定する

以後は毎朝 4:00（JST）に、6つの地方（北海道・東北／関東／中部／近畿／中国・四国／九州・沖縄）を並列で収集し、
まとめて Pages に公開する。結果はリポジトリにコミットせず、キャッシュは Actions のキャッシュに保存する。

### 配信形式

- `feed/index.json` … 作成日時・出典一覧・地域ごとのファイルの一覧（件数と内容のハッシュ）
- `feed/tiles/{行}_{列}.json` … 緯度経度 0.25° 四方ごとのイベント（行 = floor(緯度/0.25)、列 = floor(経度/0.25)）
- `events.json` … 全件（確認用）

アプリは index.json を見て、検索範囲に重なり、ハッシュが変わったファイルだけを取得する。
`EventFeedURL` が未設定のときは同梱の `ivent_check/Resources/events.json` を使う。

## 市区町村の追加（登録表）

1. `registry/municipalities_*.csv` に市区町村（コード・都道府県・名前・公式サイト・人口）を用意する
   （全国分は Wikidata から作成済み: `registry/municipalities_japan.csv`）
2. `python3 collector/detect_cms.py <一覧CSV> --output collector/registry/detected_<名前>.csv` で方式を自動判定する
3. `collect.py` は `registry/detected_*.csv` をすべて読み、対応済みの方式の市区町村を自動で収集対象にする

## ソースを増やすとき

`collector/sources/` にクラスを追加し、`collect.py` の `sources` に並べます。
`collect(now, days_ahead)` が `common.build_event(...)` で作った dict のリストを返せば動きます。
よく出てくる会場は `venues.json` に登録すると、位置が正確になります。
