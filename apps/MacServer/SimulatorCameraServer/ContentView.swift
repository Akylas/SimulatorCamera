// ContentView.swift
// macOS Companion App — Main UI

import SwiftUI
import UniformTypeIdentifiers

// MARK: - AppState (UI state only)

@MainActor
final class AppState: ObservableObject {

    private let bookmarkKey = "selectedVideoBookmark"

    @Published var selectedVideoURL: URL?
    @Published var isStreaming = false
    @Published var statusMessage = "Idle"
    @Published var sourceMode: SourceMode = .videoFile
    @Published var port: UInt16 = 9876

    enum SourceMode: String, CaseIterable {
        case videoFile = "Video File"
        case macCamera = "Mac Camera"
    }

    init() {
        restoreBookmark()
    }

    func saveBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
        } catch {
            print("Failed to save bookmark:", error)
        }
    }

    func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        var isStale = false

        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                saveBookmark(for: url)
            }

            if url.startAccessingSecurityScopedResource() {
                selectedVideoURL = url
            }

        } catch {
            print("Failed to restore bookmark:", error)
        }
    }
}


struct ContentView: View {

    @StateObject private var state = AppState()

    // ✅ IMPORTANT: FrameStreamer is now directly observed
    @StateObject private var streamer = FrameStreamer()

    let videoReader = VideoFileReader()
    let cameraReader = MacCameraReader()

    var body: some View {
        VStack(spacing: 16) {

            Text("Simulator Camera Server")
                .font(.title2.bold())

            Divider()

            // MARK: Source Picker
            Picker("Source", selection: $state.sourceMode) {
                ForEach(AppState.SourceMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(state.isStreaming)

            // MARK: File Picker
            if state.sourceMode == .videoFile {
                HStack {
                    Text(state.selectedVideoURL?.lastPathComponent ?? "No file selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)

                    Button("Choose File…") {
                        pickVideoFile()
                    }
                    .disabled(state.isStreaming)
                }
            }

            // MARK: Port
            HStack {
                Text("Port:")
                TextField("Port", value: $state.port, format: .number)
                    .frame(width: 70)
                    .disabled(state.isStreaming)
            }

            Divider()

            // MARK: Status
            VStack(spacing: 8) {

                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)

                    Text(state.statusMessage)
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                if state.isStreaming {
                    HStack {

                        Label(
                            "\(String(format: "%.1f", streamer.currentFPS)) FPS",
                            systemImage: "speedometer"
                        )

                        Spacer()

                        Label(
                            streamer.isClientConnected
                                ? "Client connected"
                                : "Waiting for client…",
                            systemImage: streamer.isClientConnected
                                ? "checkmark.circle.fill"
                                : "circle.dashed"
                        )
                        .foregroundStyle(
                            streamer.isClientConnected ? .green : .orange
                        )
                    }
                    .font(.caption)
                }
            }

            Spacer()

            // MARK: Start / Stop
            Button {
                if state.isStreaming {
                    stopStreaming()
                } else {
                    Task { await startStreaming() }
                }
            } label: {
                Text(state.isStreaming ? "Stop Streaming" : "Start Streaming")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(state.isStreaming ? .red : .blue)
        }
        .padding(20)
    }

    // MARK: - Streaming Logic

    func startStreaming() async {

        streamer.stopServer()
        streamer.port = state.port
        streamer.startServer()

        state.isStreaming = true
        state.statusMessage = "Starting..."

        switch state.sourceMode {

        case .videoFile:
            guard let url = state.selectedVideoURL else {
                state.statusMessage = "No video file selected"
                return
            }

            do {
                state.statusMessage = "Loading video..."
                try await videoReader.loadVideo(url: url)

                videoReader.onFrame = { [weak streamer] image, timestamp in
                    streamer?.sendFrame(image: image, timestamp: timestamp)
                }

                videoReader.startPlaying()

                state.statusMessage = "Streaming video file"

            } catch {
                state.statusMessage = "Error: \(error.localizedDescription)"
            }

        case .macCamera:
            do {
                try cameraReader.configure()

                cameraReader.onFrame = { [weak streamer] image, timestamp in
                    streamer?.sendFrame(image: image, timestamp: timestamp)
                }

                cameraReader.start()

                state.statusMessage = "Streaming camera"

            } catch {
                state.statusMessage = "Camera error: \(error.localizedDescription)"
            }
        }
    }

    func stopStreaming() {
        videoReader.stopPlaying()
        cameraReader.stop()
        streamer.stopServer()

        state.isStreaming = false
        state.statusMessage = "Stopped"
    }

    // MARK: - File Picker

    private func pickVideoFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .movie,
            .mpeg4Movie,
            .quickTimeMovie,
            .avi
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            state.selectedVideoURL = url
            state.saveBookmark(for: url)
        }
    }

    // MARK: - UI State

    private var statusColor: Color {
        if state.isStreaming && streamer.isClientConnected { return .green }
        if state.isStreaming { return .orange }
        return .gray
    }
}
