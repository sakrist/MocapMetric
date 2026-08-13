import SwiftUI

struct WatchSyncStatusLabel: View {
    let pendingSessionCount: Int
    let isSyncing: Bool

    var body: some View {
        Text(statusText)
            .font(.caption2.weight(isSyncing ? .semibold : .regular))
            .foregroundStyle(isSyncing && pendingSessionCount > 0 ? .orange : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(statusText)
    }

    private var statusText: String {
        if pendingSessionCount == 0 {
            return "All sessions synced"
        }
        if isSyncing {
            return "Syncing \(sessionCountText)"
        }
        return "\(sessionCountText) waiting to sync"
    }

    private var sessionCountText: String {
        "\(pendingSessionCount) session\(pendingSessionCount == 1 ? "" : "s")"
    }
}

#Preview("Syncing") {
    WatchSyncStatusLabel(pendingSessionCount: 2, isSyncing: true)
        .padding()
}

#Preview("Complete") {
    WatchSyncStatusLabel(pendingSessionCount: 0, isSyncing: false)
        .padding()
}
