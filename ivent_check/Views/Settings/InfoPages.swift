import SwiftUI

/// データ出典一覧（D-07 出典表示）
struct DataSourcesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.repository.dataSources) { source in
            VStack(alignment: .leading, spacing: 6) {
                Link(source.name, destination: source.url)
                    .font(.headline)
                Text("ライセンス：\(source.license)")
                    .font(.subheadline)
                Text(source.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("データ出典一覧")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        DocumentView(title: "プライバシーポリシー", sections: [
            ("取得する情報", "本アプリは、周辺のイベントを検索するために端末の位置情報を利用します。位置情報の利用は原則として「アプリの使用中のみ」とし、「移動先でも検知」をオンにした場合に限り「常に許可」を求めます。"),
            ("位置情報の取り扱い", "検索のためにサーバーへ送信する座標は約1km単位に丸めます。位置の履歴は保存しません。通知の作成のため、丸めた直近の位置1点のみを端末内に保存します。"),
            ("端末内に保存する情報", "お気に入り、直近の検索結果、通知や検索エリアの設定は端末内にのみ保存されます。"),
            ("カレンダー", "カレンダーへの登録は、ユーザーが登録画面で保存を選んだ場合にのみ行います。カレンダーの内容を読み取ることはありません。"),
            ("第三者提供", "取得した情報を広告・トラッキング目的で第三者に提供することはありません。"),
        ])
    }
}

struct DisclaimerView: View {
    var body: some View {
        DocumentView(title: "免責事項", sections: [
            ("情報の正確性", "掲載しているイベント情報は、各情報源から自動的に収集・整理したものです。内容の正確性・完全性は保証されません。"),
            ("お出かけ前に", "天候等による中止・延期や内容の変更が発生する場合があります。お出かけ前に必ず公式サイトや主催者の案内で最新情報をご確認ください。"),
            ("要確認の表示", "自動抽出の信頼度が低い情報には「要確認」と表示しています。"),
            ("誤りの報告", "情報に誤りを見つけた場合は、イベント詳細画面の「情報が間違っている場合は報告」からお知らせください。"),
        ])
    }
}

private struct DocumentView: View {
    let title: String
    let sections: [(String, String)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(sections, id: \.0) { heading, body in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(heading).font(.headline)
                        Text(body).font(.body)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
