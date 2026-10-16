# イベント収集バッチ

毎朝1回、公開されているイベント情報を集めて `docs/events.json` を作ります。
アプリはこの JSON を取得し、端末側で現在地からの距離と日付で絞り込みます。
サーバー・データベース・AI は使いません（Python 標準ライブラリのみ）。

## 取得元

| ソース | 取得方法 | 備考 |
|---|---|---|
| 宝塚市ホームページ イベントカレンダー | `city_event.js`（カレンダー画面が読み込む構造化データ） | 日付のみ。時刻は説明文に1種類だけ書かれている場合に採用 |
| 宝塚市立公民館（中央・東・西） | WordPress REST API | 本文の「日時：」行をルールで解析。読めないものは載せない |
| 国土地理院 住所検索API / OpenStreetMap | 会場の緯度経度 | 結果は `geocode_cache.json` に保存し再問い合わせしない |

どちらのサイトも再利用条件が明示されていないため、名称・日時・会場・料金などの事実情報とリンクのみを載せ、
本文や画像は転載しません（アプリでは種類別に用意したアイコンを表示）。

## ローカルで実行

```bash
python3 collector/collect.py --output docs/events.json
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
