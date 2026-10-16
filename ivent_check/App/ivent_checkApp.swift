//
//  ivent_checkApp.swift
//  ivent_check
//
//  Created by 片山皓仁 on 2026/10/15.
//

import SwiftUI
import SwiftData

@main
struct ivent_checkApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .modelContainer(model.modelContainer)
        .backgroundTask(.appRefresh(AppModel.refreshTaskID)) {
            await AppModel.shared.handleBackgroundRefresh()
        }
    }
}
