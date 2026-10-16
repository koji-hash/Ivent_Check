import SwiftUI

/// 4.2 F-EVT-03 のカテゴリ
nonisolated enum EventCategory: String, Codable, CaseIterable, Identifiable, Hashable {
    case festival
    case fireworks
    case market
    case music
    case art
    case sports
    case kids
    case food
    case community
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .festival: "祭り"
        case .fireworks: "花火"
        case .market: "マルシェ・朝市"
        case .music: "音楽"
        case .art: "展示・アート"
        case .sports: "スポーツ"
        case .kids: "子ども向け"
        case .food: "グルメ"
        case .community: "地域行事"
        case .other: "その他"
        }
    }

    var symbol: String {
        switch self {
        case .festival: "party.popper"
        case .fireworks: "sparkles"
        case .market: "basket"
        case .music: "music.note"
        case .art: "paintpalette"
        case .sports: "figure.run"
        case .kids: "figure.and.child.holdinghands"
        case .food: "fork.knife"
        case .community: "building.columns"
        case .other: "star"
        }
    }

    var color: Color {
        switch self {
        case .festival: .red
        case .fireworks: .purple
        case .market: .green
        case .music: .pink
        case .art: .indigo
        case .sports: .orange
        case .kids: .teal
        case .food: .brown
        case .community: .blue
        case .other: .gray
        }
    }
}
