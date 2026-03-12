import SwiftUI

struct ContentView: View {
    @StateObject private var inboxStore = RecordingInboxStore()

    var body: some View {
        NavigationStack {
            List {
                if inboxStore.recordings.isEmpty {
                    Text("No recordings yet. Record on watch, then stop to queue transfer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(inboxStore.recordings) { recording in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recording.fileName)
                                    .font(.subheadline)
                                    .lineLimit(1)

                                Text(recording.createdAt, format: Date.FormatStyle(date: .numeric, time: .standard))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(recording.fileSizeLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            ShareLink(item: recording.url) {
                                Image(systemName: "square.and.arrow.up")
                                    .imageScale(.large)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Watch Recordings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") {
                        inboxStore.reloadRecordings()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(inboxStore.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
            }
        }
    }
}

#Preview {
    ContentView()
}
