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
2. リポジトリの Settings → Pages → Source を「Deploy from a branch」、Branch を `main` / `/docs` にする
3. Actions タブで `collect-events` を一度手動実行（Run workflow）して動作を確認する
4. `https://<ユーザー名>.github.io/<リポジトリ名>/events.json` が開けたら、
   アプリの `ivent_check-Info.plist` の `EventFeedURL` にその URL を設定する

以後は毎朝 5:00（JST）に自動更新されます。

アプリには公開前・通信できないとき用に `ivent_check/Resources/events.json` を同梱しています。
リリース前には `cp docs/events.json ivent_check/Resources/events.json` で最新にしてください。

## ソースを増やすとき

`collector/sources/` にクラスを追加し、`collect.py` の `sources` に並べます。
`collect(now, days_ahead)` が `common.build_event(...)` で作った dict のリストを返せば動きます。
よく出てくる会場は `venues.json` に登録すると、位置が正確になります。
