import SwiftUI
import UIKit
import EventKit
import EventKitUI

/// F-DTL-04 EventKit で端末カレンダーに登録する。
/// iOS 17 以降、EKEventEditViewController はカレンダーへのアクセス許可なしで利用できる。
struct CalendarEventEditor: UIViewControllerRepresentable {
    let event: Event
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onDone: { dismiss() })
    }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = event.title
        ekEvent.isAllDay = event.isAllDay
        ekEvent.startDate = event.startAt
        // 終日イベントの endAt は翌日0:00のため、最終日に合わせる
        ekEvent.endDate = event.isAllDay ? event.endAt.addingTimeInterval(-1) : event.endAt
        ekEvent.location = [event.venueName, event.address].compactMap { $0 }.joined(separator: " ")
        ekEvent.url = event.officialUrl ?? event.sourceUrl
        ekEvent.notes = [event.summary, "出典：\(event.sourceName)"].compactMap { $0 }.joined(separator: "\n\n")

        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = ekEvent
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onDone: () -> Void

        init(onDone: @escaping () -> Void) {
            self.onDone = onDone
        }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onDone()
        }
    }
}
