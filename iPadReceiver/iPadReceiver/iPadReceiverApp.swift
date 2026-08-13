import SwiftUI

@main
struct iPadReceiverApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @AppStorage("appMode") private var appMode = ""
    @State private var modeSelected = false

    var body: some View {
        if modeSelected || appMode == "receive" {
            ContentView()
        } else {
            ModePicker(select: { mode in
                appMode = mode
                modeSelected = true
            })
        }
    }
}

struct ModePicker: View {
    let select: (String) -> Void

    var body: some View {
        ZStack {
            Color(UIColor.secondarySystemBackground).ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "display.2")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)
                Text("投屏").font(.largeTitle.bold())

                VStack(spacing: 16) {
                    Button {
                        select("receive")
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2)
                            Text("接收")
                                .font(.title3.bold())
                        }
                        .frame(width: 220, height: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button {
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                            Text("投屏")
                                .font(.title3.bold())
                        }
                        .frame(width: 220, height: 64)
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                    .disabled(true)
                }

                Text("iPad 端暂不支持投屏其他 App")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
