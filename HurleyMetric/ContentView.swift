import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var videoRecorder: PhoneVideoRecorder
    @StateObject private var inboxStore: RecordingInboxStore
    @State private var selectedRecording: RecordingSession?

    init() {
        let videoRecorder = PhoneVideoRecorder()
        _videoRecorder = StateObject(wrappedValue: videoRecorder)
        _inboxStore = StateObject(wrappedValue: RecordingInboxStore(videoRecorder: videoRecorder))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("iPhone Video") {
                    Toggle("Record iPhone video with watch", isOn: Binding(
                        get: { videoRecorder.isArmed },
                        set: { videoRecorder.setArmed($0) }
                    ))

                    Text("Keep the iPhone app open and reachable. Remote video start/stop only works while this app is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if videoRecorder.isArmed {
                        ZStack {
                            CameraPreviewView(session: videoRecorder.captureSession)
                            if videoRecorder.showSyncFlash {
                                Rectangle()
                                    .fill(Color.white)
                            }
                        }
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        Text(videoRecorder.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Recordings") {
                if inboxStore.recordings.isEmpty {
                    Text("No recordings yet. Record on watch, then stop to queue transfer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(inboxStore.recordings) { recording in
                        HStack(spacing: 12) {
                            NavigationLink {
                                RecordingDetailView(recording: recording)
                                    .environmentObject(inboxStore)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recording.title)
                                        .font(.subheadline)
                                        .lineLimit(1)

                                    Text(recording.createdAt, format: Date.FormatStyle(date: .numeric, time: .standard))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Text("\(recording.detailLabel) • \(recording.totalSizeLabel)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button {
                                selectedRecording = recording
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .imageScale(.large)
                            }
                            .buttonStyle(.plain)
                            .disabled(recording.shareItems.isEmpty)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: inboxStore.deleteRecordings)
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
            .sheet(item: $selectedRecording) { recording in
                ActivityView(items: recording.shareItems)
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}

#Preview {
    ContentView()
}
