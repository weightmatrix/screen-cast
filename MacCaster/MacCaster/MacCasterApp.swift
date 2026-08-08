import SwiftUI

@main
struct MacCasterApp: App {
    @StateObject private var streamer = ScreenStreamer()
    @StateObject private var server = CastingServer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(streamer)
                .environmentObject(server)
        }
        .defaultSize(width: 680, height: 540)
    }
}