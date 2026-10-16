import SwiftUI

/// F-DTL-06 「情報が間違っている」報告
struct ReportIssueView: View {
    let event: Event

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var reason: EventIssueReport.Reason = .wrongDate
    @State private var comment = ""
    @State private var isSending = false
    @State private var didSend = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(event.title).font(.headline)
                }
                Section("内容") {
                    Picker("内容", selection: $reason) {
                        ForEach(EventIssueReport.Reason.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    TextField("正しい情報や気づいた点（任意）", text: $comment, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("詳細")
                } footer: {
                    Text("いただいた報告は情報の確認・修正に利用します。個人情報は入力しないでください。")
                }
            }
            .navigationTitle("情報の誤りを報告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("送信", action: send).bold()
                    }
                }
            }
            .alert("ご報告ありがとうございます", isPresented: $didSend) {
                if let url = event.officialUrl {
                    Button("掲載元のページを開く") {
                        openURL(url)
                        dismiss()
                    }
                }
                Button("閉じる") { dismiss() }
            } message: {
                Text("報告は端末に記録しました。最新の情報は掲載元のページでご確認ください。")
            }
            .alert("送信できませんでした", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func send() {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await model.repository.reportIssue(.init(eventID: event.id, reason: reason,
                                                             comment: comment, reportedAt: .now))
                didSend = true
            } catch {
                errorMessage = "通信環境の良い場所で再度お試しください。"
            }
        }
    }
}
