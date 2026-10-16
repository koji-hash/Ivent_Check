import SwiftUI
import UIKit
import CoreLocation
import UserNotifications

/// S-07 設定
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showAreaSearch = false
    @State private var showNotificationDenied = false

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                areaSection(settings)
                morningSection(settings)

                Section {
                    Toggle("お気に入りのリマインド", isOn: $settings.favoriteRemindersEnabled)
                } footer: {
                    Text("お気に入りのイベントを前日19:00と開始1時間前にお知らせします。")
                }

                Section {
                    Toggle("静音時間", isOn: $settings.quietHoursEnabled)
                    if settings.quietHoursEnabled {
                        Picker("開始", selection: $settings.quietStartHour) { hourOptions }
                        Picker("終了", selection: $settings.quietEndHour) { hourOptions }
                    }
                } header: {
                    Text("静音時間")
                } footer: {
                    Text("この時間帯は通知しません。リマインドは静音時間の終了後にお知らせします。")
                }

                Section {
                    Toggle("移動先でも検知", isOn: Binding(
                        get: { settings.followLocationChanges },
                        set: { model.setFollowLocationChanges($0) }))
                } footer: {
                    Text("大きく移動したとき（旅行・出張など）に、移動先の周辺イベントで朝の通知を作り直します。位置情報の「常に許可」が必要です。常時GPSは使用せず、電池への影響は最小限です。")
                }

                Section("このアプリについて") {
                    NavigationLink("データ出典一覧") { DataSourcesView() }
                    NavigationLink("プライバシーポリシー") { PrivacyPolicyView() }
                    NavigationLink("免責事項") { DisclaimerView() }
                    LabeledContent("バージョン", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                }

                #if DEBUG
                Section("開発用") {
                    Button("5秒後にテスト通知") { sendTestNotification() }
                    Button("オンボーディングをやり直す") { settings.hasCompletedOnboarding = false }
                }
                #endif
            }
            .navigationTitle("設定")
            .sheet(isPresented: $showAreaSearch) {
                AreaSearchView { model.setManualArea($0) }
            }
            .alert("通知がオフになっています", isPresented: $showNotificationDenied) {
                Button("設定を開く") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                Button("閉じる", role: .cancel) {}
            } message: {
                Text("設定アプリでこのアプリの通知を許可してください。")
            }
            .onChange(of: notificationSettingsKey) { model.scheduleNotificationRefresh() }
        }
    }

    // MARK: - セクション

    private func areaSection(_ settings: AppSettings) -> some View {
        @Bindable var settings = settings
        return Section {
            Toggle("エリアを手動で指定する", isOn: Binding(
                get: { settings.useManualArea },
                set: { newValue in
                    if newValue, settings.manualArea == nil {
                        showAreaSearch = true
                    } else {
                        settings.useManualArea = newValue
                        model.scheduleNotificationRefresh()
                    }
                }))
            Button {
                showAreaSearch = true
            } label: {
                LabeledContent("指定エリア", value: settings.manualArea?.name ?? "未設定")
            }
            .foregroundStyle(.primary)
            LabeledContent("位置情報", value: locationStatusText)
            if model.location.isDenied || model.location.authorizationStatus == .notDetermined {
                Button("位置情報の利用を許可する") {
                    if model.location.authorizationStatus == .notDetermined {
                        model.location.requestWhenInUse()
                    } else {
                        openURL(URL(string: UIApplication.openSettingsURLString)!)
                    }
                }
            }
        } header: {
            Text("検索エリア")
        } footer: {
            Text("位置情報を許可しない場合は、駅名・地名でエリアを指定できます。")
        }
    }

    private func morningSection(_ settings: AppSettings) -> some View {
        @Bindable var settings = settings
        return Section {
            Toggle("朝の通知", isOn: Binding(
                get: { settings.morningNotificationEnabled },
                set: { newValue in
                    guard newValue else { settings.morningNotificationEnabled = false; return }
                    Task {
                        switch await model.scheduler.authorizationStatus() {
                        case .notDetermined:
                            _ = await model.enableNotifications()
                        case .denied:
                            showNotificationDenied = true
                        default:
                            settings.morningNotificationEnabled = true
                        }
                    }
                }))
            if settings.morningNotificationEnabled {
                DatePicker("時刻", selection: $settings.morningTime, displayedComponents: .hourAndMinute)
                Picker("頻度", selection: $settings.notificationFrequency) {
                    ForEach(NotificationFrequency.allCases) { Text($0.label).tag($0) }
                }
                Picker("範囲", selection: $settings.notificationRadiusKm) {
                    ForEach(SearchFilter.radiusOptions, id: \.self) { Text("\(Int($0))km以内").tag($0) }
                }
                NavigationLink {
                    NotificationCategoryView()
                } label: {
                    LabeledContent("カテゴリ", value: settings.notificationCategories.isEmpty
                                   ? "すべて" : "\(settings.notificationCategories.count)件選択")
                }
            }
        } header: {
            Text("朝の通知")
        } footer: {
            if settings.morningNotificationEnabled, settings.isQuiet(hour: settings.morningHour) {
                Text("通知時刻が静音時間に含まれているため、朝の通知は届きません。")
                    .foregroundStyle(.orange)
            } else {
                Text("今日近くで開催されるイベントの件数と代表イベントをお知らせします。")
            }
        }
    }

    @ViewBuilder
    private var hourOptions: some View {
        ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) }
    }

    private var locationStatusText: String {
        switch model.location.authorizationStatus {
        case .authorizedAlways: "常に許可"
        case .authorizedWhenInUse: "使用中のみ許可"
        case .denied: "許可されていません"
        case .restricted: "制限されています"
        case .notDetermined: "未設定"
        @unknown default: "-"
        }
    }

    /// 通知に影響する設定が変わったら作り直す
    private var notificationSettingsKey: String {
        let s = model.settings
        return [s.morningNotificationEnabled.description, "\(s.morningHour):\(s.morningMinute)", s.notificationFrequency.rawValue,
                "\(s.notificationRadiusKm)", s.notificationCategories.map(\.rawValue).sorted().joined(separator: ","),
                s.quietHoursEnabled.description, "\(s.quietStartHour)-\(s.quietEndHour)", s.favoriteRemindersEnabled.description]
            .joined(separator: "|")
    }

    #if DEBUG
    private func sendTestNotification() {
        Task {
            if await model.scheduler.authorizationStatus() == .notDetermined {
                await model.scheduler.requestAuthorization()
            }
            let content = UNMutableNotificationContent()
            content.title = "今日、近くで\(model.store.hits.count)件のイベント"
            content.body = model.store.visibleHits.first.map { "\($0.event.title) ほか" } ?? "テスト通知です"
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: content, trigger: trigger))
        }
    }
    #endif
}

/// 通知対象カテゴリの選択
private struct NotificationCategoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                CategoryGrid(selection: $settings.notificationCategories)
            } footer: {
                Text("未選択の場合はすべてのカテゴリを通知します。")
            }
        }
        .navigationTitle("通知するカテゴリ")
        .navigationBarTitleDisplayMode(.inline)
    }
}
