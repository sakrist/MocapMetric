import SwiftUI

struct WatchSyncStatusView: View {
    let isConnected: Bool
    let isSyncing: Bool
    let isRecording: Bool
    let pendingSessionCount: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.16))

                if isSyncing, !isRecording {
                    ProgressView()
                        .controlSize(.small)
                        .tint(statusTint)
                } else {
                    Image(systemName: isRecording ? "record.circle.fill" : "applewatch")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(statusTint)
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if isRecording {
            return "Recording on watch"
        }
        if isSyncing {
            return "Syncing watch sessions"
        }
        if isConnected {
            return "Watch available"
        }
        return "Watch unavailable"
    }

    private var subtitle: String {
        if isRecording {
            return "Motion capture is active"
        }
        if isSyncing {
            if pendingSessionCount > 0 {
                return "Receiving \(pendingSessionCount) session\(pendingSessionCount == 1 ? "" : "s")"
            }
            return "Receiving recording files"
        }
        if isConnected {
            return pendingSessionCount == 0
                ? "All sessions synced"
                : "\(pendingSessionCount) session\(pendingSessionCount == 1 ? "" : "s") waiting to sync"
        }
        return "Check pairing and the Watch app installation"
    }

    private var statusTint: Color {
        if isRecording {
            return .red
        }
        if isSyncing {
            return .orange
        }
        if isConnected {
            return .green
        }
        return .gray
    }
}

#Preview("Syncing") {
    List {
        WatchSyncStatusView(
            isConnected: true,
            isSyncing: true,
            isRecording: false,
            pendingSessionCount: 2
        )
    }
}

#Preview("Complete") {
    List {
        WatchSyncStatusView(
            isConnected: true,
            isSyncing: false,
            isRecording: false,
            pendingSessionCount: 0
        )
    }
}
