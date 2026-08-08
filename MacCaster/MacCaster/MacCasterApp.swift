import SwiftUI

@main
struct MacCasterApp: App {
    @StateObject private var streamer = ScreenStreamer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(streamer)
        }
        .defaultSize(width: 700, height: 520)
    }
}