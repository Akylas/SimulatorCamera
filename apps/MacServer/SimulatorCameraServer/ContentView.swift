// ContentView.swift
// macOS Companion App — Main UI

import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    private let bookmarkKey = "selectedVideoBookmark"
    @Published var selectedVideoURL: URL?
    @Published var isStreaming = false
    @Published var statusMessage = "Idle"
    @Published var sourceMode: SourceMode = .videoFile
//    @Published var fpsLimit: Double = 30
    @Published var port: UInt16 = 9876
    
    init() {
        restoreBookmark()
    }

    enum SourceMode: String, CaseIterable {
        case videoFile = "Video File"
        case macCamera = "Mac Camera"
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
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return
        }

        var isStale = false

        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                // regenerate bookmark
                saveBookmark(for: url)
            }

            if url.startAccessingSecurityScopedResource() {
                selectedVideoURL = url
            } else {
                print("Failed to access security-scoped resource")
            }

        } catch {
            print("Failed to restore bookmark:", error)
        }
    }

    let streamer = FrameStreamer()
    let videoReader = VideoFileReader()
    let cameraReader = MacCameraReader()

    func startStreaming() async {
        streamer.stopServer()
        streamer.port = port
        let newStreamer = streamer
        newStreamer.startServer()

        switch sourceMode {
        case .videoFile:
            guard let url = selectedVideoURL else {
                statusMessage = "No video file selected"
                return
            }
            do {
//                videoReader.fpsLimit = fpsLimit
                statusMessage = "Loading video..."
                try await videoReader.loadVideo(url: url)
                videoReader.onFrame = { [weak newStreamer] image, timestamp in
                    newStreamer?.sendFrame(image: image, timestamp: timestamp)
                }
                videoReader.startPlaying()
                isStreaming = true
                statusMessage = "Streaming from video file (looping)"
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }

        case .macCamera:
            do {
                try cameraReader.configure()
                cameraReader.onFrame = { [weak newStreamer] image, timestamp in
                    newStreamer?.sendFrame(image: image, timestamp: timestamp)
                }
                cameraReader.start()
                isStreaming = true
                statusMessage = "Streaming from Mac camera"
            } catch {
                statusMessage = "Camera error: \(error.localizedDescription)"
            }
        }
    }

    func stopStreaming() {
        videoReader.stopPlaying()
        cameraReader.stop()
        streamer.stopServer()
        isStreaming = false
        statusMessage = "Stopped"
    }
}


struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        VStack(spacing: 16) {
            // Header
            Text("Simulator Camera Server")
                .font(.title2.bold())

            Divider()

            // Source selection
            Picker("Source", selection: $state.sourceMode) {
                ForEach(AppState.SourceMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(state.isStreaming)

            // Video file picker (only for video mode)
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

            // Settings
            HStack {
//                Text("FPS Limit:")
//                TextField("FPS", value: $state.fpsLimit, format: .number)
//                    .frame(width: 60)
//                    .disabled(state.isStreaming)
//
//                Spacer()

                Text("Port:")
                TextField("Port", value: $state.port, format: .number)
                    .frame(width: 70)
                    .disabled(state.isStreaming)
            }

            Divider()

            // Status
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
                        Label("\(String(format: "%.1f", state.streamer.currentFPS)) FPS",
                              systemImage: "speedometer")
//                        Spacer()
//                        Label("\(state.streamer.framesSent) frames sent",
//                              systemImage: "photo.stack")
                        Spacer()
                        Label(state.streamer.isClientConnected ? "Client connected" : "Waiting for client…",
                              systemImage: state.streamer.isClientConnected ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(state.streamer.isClientConnected ? .green : .orange)
                    }
                    .font(.caption)
                }
            }

            Spacer()

            // Start / Stop
            Button(action: {
                if state.isStreaming {
                    state.stopStreaming()
                } else {
                    Task { await state.startStreaming() }
                }
            }) {
                Text(state.isStreaming ? "Stop Streaming" : "Start Streaming")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(state.isStreaming ? .red : .blue)
        }
        .padding(20)
    }

    private var statusColor: Color {
        if state.isStreaming && state.streamer.isClientConnected { return .green }
        if state.isStreaming { return .orange }
        return .gray
    }

    private func pickVideoFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType.movie,
            UTType.mpeg4Movie,
            UTType.quickTimeMovie,
            UTType.avi
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            state.selectedVideoURL = url
            state.saveBookmark(for: url) 
        }
    }
}
