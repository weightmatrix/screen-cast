import Foundation

final class DiagLog { static func log(_ tag: String, _ text: String) {} }

/// Receive-only check against the user's already running, real Mac capture.
/// Never creates a sender, changes matching codes or occupies broadcast ports.
@main enum LiveMacReceiveCheck {
    @MainActor static func main() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.count == 2, MatchingCode.isValid(args[1]),
              let password = ProcessInfo.processInfo.environment["TOUPING_CHECK_PASSWORD"], AdmissionCredentials.validPassword(password) else { exit(2) }
        var failures = 0
        var referenceRatio: CGFloat?
        for mode in ["localIP", "internetCode"] {
            let client = MacReceiverClient()
            client.connectionPassword = password; client.applicationText = "本机接收验收申请，请主控手动确认"
            if mode == "localIP" { client.connect(host: "127.0.0.1", port: 8318, code: args[1]) }
            else { client.connectInternetCode(args[1]) }
            for _ in 0..<300 {
                if client.frameCount >= 60 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let size = client.decoder.frameForDisplay(after: nil)?.image?.extent.size
            let ratio = size.map { $0.width / $0.height }
            if mode == "localIP" { referenceRatio = ratio }
            let sameSourceShape = ratio.flatMap { r in referenceRatio.map { abs(r - $0) < 0.02 } } ?? false
            let passed = client.frameCount >= 60 && sameSourceShape
            if !passed { failures += 1 }
            print("LiveMacReceive \(passed ? "PASS" : "FAIL") mode=\(mode) frames=\(client.frameCount) size=\(String(describing: size)) status=\(client.status)")
            client.disconnect()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        exit(failures == 0 ? 0 : 1)
    }
}
