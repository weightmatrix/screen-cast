import SwiftUI

@main
struct MacCasterApp: App {
    @StateObject private var streamer = ScreenStreamer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(streamer)
        }
        .defaultSize(width: 700, height: 520)
    }
}

struct RootView: View {
    @AppStorage("appMode") private var appMode = "cast"

    var body: some View {
        if appMode == "receive" {
            MacReceiverView()
        } else {
            ContentView()
        }
    }
}

struct MacModePicker: View {
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "display.2")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
            Text("投屏").font(.largeTitle.bold())

            HStack(spacing: 24) {
                Button {
                    select("cast")
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                        Text("投屏").font(.title3.bold())
                    }
                    .frame(width: 140, height: 90)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button {
                    select("receive")
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").font(.title)
                        Text("接收").font(.title3.bold())
                    }
                    .frame(width: 140, height: 90)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(40)
        .frame(width: 420, height: 320)
    }
}
