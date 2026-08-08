import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var videoRecorder: PhoneVideoRecorder
    @StateObject private var inboxStore: RecordingInboxStore
    @State private var selectedRecording: RecordingSession?
    @State private var showingVideoRecorder = false

    init() {
        let videoRecorder = PhoneVideoRecorder()
        _videoRecorder = StateObject(wrappedValue: videoRecorder)
        _inboxStore = StateObject(wrappedValue: RecordingInboxStore(videoRecorder: videoRecorder))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("iPhone Video") {
                    Button("Open Video Recorder") {
                        videoRecorder.openVideoRecorder()
                        showingVideoRecorder = true
                    }
                    .buttonStyle(.borderedProminent)
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
            .fullScreenCover(isPresented: $showingVideoRecorder) {
                VideoRecorderView(videoRecorder: videoRecorder) {
                    showingVideoRecorder = false
                    videoRecorder.closeVideoRecorder()
                }
            }
        }
    }
}

private struct VideoRecorderView: View {
    @ObservedObject var videoRecorder: PhoneVideoRecorder
    let onBack: () -> Void

    private var isSessionActive: Bool {
        videoRecorder.isVideoSessionActive || videoRecorder.isRecording
    }

    private var indicatorTitle: String {
        if videoRecorder.isRecording { return "Recording" }
        if videoRecorder.isVideoSessionActive { return "Starting" }
        if videoRecorder.isConfigured { return "Ready for Watch" }
        return "Preparing camera"
    }

    var body: some View {
        ZStack {
            CameraPreviewView(session: videoRecorder.captureSession)
                .ignoresSafeArea()

            if videoRecorder.showSyncFlash {
                Color.white
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Button("Back", systemImage: "chevron.left") {
                        onBack()
                    }
                    .disabled(isSessionActive)

                    Spacer()

                    HStack(spacing: 6) {
                        Circle()
                            .fill(videoRecorder.isRecording ? .red : .white.opacity(0.65))
                            .frame(width: 10, height: 10)
                        Text(indicatorTitle)
                            .font(.headline.weight(.semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                Text(videoRecorder.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 28)
            }
        }
        .background(.black)
        .interactiveDismissDisabled()
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
