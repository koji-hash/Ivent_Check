import SwiftUI
import CoreLocation

/// S-01 オンボーディング。許可を求める前に理由を説明する
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var showAreaSearch = false

    var body: some View {
        TabView(selection: $step) {
            page(symbol: "party.popper.fill", color: .pink,
                 title: "近くのイベントに、\n気づける。",
                 message: "現在地のまわりで今日・近日に開催される祭りや催し、地域イベントを自動で見つけてお知らせします。\n\n全国の市区町村が公開しているイベント情報を毎日集めています（対応する市区町村は順次拡大中）。") {
                Button("はじめる") { withAnimation { step = 1 } }
                    .buttonStyle(.borderedProminent)
            }
            .tag(0)

            page(symbol: "location.fill", color: .blue,
                 title: "位置情報の利用について",
                 message: "現在地の周辺にあるイベントを探すために使用します。\n\n・位置は約1km単位に丸めて検索に使います\n・位置の履歴は保存しません\n・アプリ使用中のみ取得します") {
                Button("位置情報を許可する") { model.location.requestWhenInUse() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.location.authorizationStatus != .notDetermined)
                Button("許可せずに駅名・地名で指定する") { showAreaSearch = true }
            }
            .tag(1)

            page(symbol: "bell.badge.fill", color: .orange,
                 title: "通知でお知らせ",
                 message: "毎朝8:00に「今日近くで開催されるイベント」をお知らせします。お気に入りのイベントは前日と開始1時間前にリマインドします。\n\n時刻・距離・カテゴリ・静音時間は設定でいつでも変更できます。") {
                Button("通知を許可する") {
                    Task {
                        _ = await model.enableNotifications()
                        finish()
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("あとで") {
                    model.settings.morningNotificationEnabled = false
                    finish()
                }
            }
            .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .onChange(of: model.location.authorizationStatus) { _, status in
            if status != .notDetermined, step == 1 { withAnimation { step = 2 } }
        }
        .sheet(isPresented: $showAreaSearch) {
            AreaSearchView { area in
                model.setManualArea(area)
                withAnimation { step = 2 }
            }
        }
    }

    private func finish() {
        model.settings.hasCompletedOnboarding = true
    }

    private func page(symbol: String, color: Color, title: String, message: String,
                      @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 72))
                .foregroundStyle(color.gradient)
                .accessibilityHidden(true)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            VStack(spacing: 12) {
                actions()
            }
            .controlSize(.large)
            .padding(.bottom, 56)
        }
        .padding(.horizontal, 32)
    }
}
