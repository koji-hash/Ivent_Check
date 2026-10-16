import SwiftUI
import CoreLocation

/// F-EVT-06 ステータスバッジ
struct StatusBadge: View {
    let status: EventStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(status.color, in: Capsule())
    }
}

/// 抽出の信頼度が低いイベントの「要確認」表示
struct VerificationBadge: View {
    var body: some View {
        Label("要確認", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.bold())
            .foregroundStyle(.orange)
            .accessibilityLabel("情報が不確かなため要確認")
    }
}

/// リスト行
struct EventRow: View {
    let event: Event
    let distance: CLLocationDistance?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            EventIconView(icon: event.icon)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StatusBadge(status: .of(event))
                    if event.isFree == true {
                        Text("無料").font(.caption2.bold()).foregroundStyle(.green)
                    }
                    if event.needsVerification { VerificationBadge() }
                }
                Text(event.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(EventFormatters.schedule(for: event))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label {
                    Text([event.venueName, event.displayArea, distance.map { EventFormatters.distance($0) }]
                        .compactMap { $0 }.joined(separator: "・"))
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// 地図下部パネルのカード
struct EventCard: View {
    let hit: EventHit
    var isSelected = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            EventIconView(icon: hit.event.icon, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StatusBadge(status: .of(hit.event))
                    if hit.event.needsVerification { VerificationBadge() }
                }
                Text(hit.event.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(EventFormatters.schedule(for: hit.event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text([hit.event.venueName, hit.event.displayArea, EventFormatters.distance(hit.distance)]
                    .compactMap { $0 }.joined(separator: "・"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? hit.event.icon.color : .clear, lineWidth: 2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// カテゴリの複数選択グリッド（フィルタ・通知設定で共用）
struct CategoryGrid: View {
    @Binding var selection: Set<EventCategory>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
            ForEach(EventCategory.allCases) { category in
                let isSelected = selection.contains(category)
                Button {
                    if isSelected { selection.remove(category) } else { selection.insert(category) }
                } label: {
                    Label(category.label, systemImage: category.symbol)
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(isSelected ? category.color : .primary)
                        .background(isSelected ? category.color.opacity(0.15) : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? category.color : .clear, lineWidth: 1.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
