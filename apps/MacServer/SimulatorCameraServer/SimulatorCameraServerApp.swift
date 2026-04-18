// SimulatorCameraServerApp.swift
// macOS Companion App — Entry Point
// Requires: macOS 14+, Swift 5.9+, Xcode 16

import SwiftUI

@main
struct SimulatorCameraServerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 480, minHeight: 360)
        }
        .windowResizability(.contentSize)
    }
}
