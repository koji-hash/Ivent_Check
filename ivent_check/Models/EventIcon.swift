import SwiftUI

/// あらかじめ用意したイベントのアイコン。
/// 収集バッチ（collector/common.py の ICON_KEYWORDS）がタイトルから選んで `icon` に入れる。
/// 掲載元の画像は再利用条件が明示されたものしか使わないため、通常はこちらを表示する。
nonisolated enum EventIcon: String, CaseIterable, Identifiable {
    case festival, fireworks, market, food, music, theater, exhibition, craft
    case library, kids, walk, sports, health, consultation, lecture, community, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .festival: "祭り"
        case .fireworks: "花火"
        case .market: "マルシェ・市"
        case .food: "食・グルメ"
        case .music: "音楽"
        case .theater: "舞台・映画"
        case .exhibition: "展示"
        case .craft: "ものづくり"
        case .library: "本・図書館"
        case .kids: "子ども"
        case .walk: "散策"
        case .sports: "スポーツ"
        case .health: "健康・福祉"
        case .consultation: "相談"
        case .lecture: "講座・教室"
        case .community: "地域・交流"
        case .other: "イベント"
        }
    }

    var symbol: String {
        switch self {
        case .festival: "party.popper.fill"
        case .fireworks: "sparkles"
        case .market: "basket.fill"
        case .food: "fork.knife"
        case .music: "music.note"
        case .theater: "theatermasks.fill"
        case .exhibition: "photo.artframe"
        case .craft: "scissors"
        case .library: "books.vertical.fill"
        case .kids: "figure.and.child.holdinghands"
        case .walk: "figure.walk"
        case .sports: "figure.run"
        case .health: "heart.fill"
        case .consultation: "bubble.left.and.bubble.right.fill"
        case .lecture: "graduationcap.fill"
        case .community: "person.3.fill"
        case .other: "star.fill"
        }
    }

    /// グラデーションの2色（左上→右下）
    var colors: (Color, Color) {
        switch self {
        case .festival: (.red, .orange)
        case .fireworks: (.purple, .indigo)
        case .market: (.green, .mint)
        case .food: (.orange, .brown)
        case .music: (.pink, .purple)
        case .theater: (.indigo, .purple)
        case .exhibition: (.indigo, .blue)
        case .craft: (.teal, .green)
        case .library: (.brown, .orange)
        case .kids: (.teal, .cyan)
        case .walk: (.green, .teal)
        case .sports: (.orange, .red)
        case .health: (.pink, .red)
        case .consultation: (.blue, .cyan)
        case .lecture: (.blue, .indigo)
        case .community: (.blue, .teal)
        case .other: (.gray, Color(white: 0.55))
        }
    }

    var color: Color { colors.0 }

    var gradient: LinearGradient {
        LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// `icon` が無い古いデータ用：カテゴリから決める
    init(category: EventCategory) {
        self = switch category {
        case .festival: .festival
        case .fireworks: .fireworks
        case .market: .market
        case .music: .music
        case .art: .exhibition
        case .sports: .sports
        case .kids: .kids
        case .food: .food
        case .community: .community
        case .other: .other
        }
    }
}

/// 用意したアイコンの表示（角丸タイル or 円）
struct EventIconView: View {
    let icon: EventIcon
    var size: CGFloat = 44
    var circle = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: circle ? size / 2 : size * 0.26, style: .continuous)
        Image(systemName: icon.symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            .frame(width: size, height: size)
            .background(icon.gradient, in: shape)
            .accessibilityHidden(true)
    }
}
