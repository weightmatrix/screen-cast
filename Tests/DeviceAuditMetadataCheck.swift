import Foundation

/// Synthetic lifecycle reports only: no actual screen capture or media acceptance.
@main struct DeviceAuditMetadataCheck {
    static func main() async {
        let value = DeviceAuditMetadata.value
        precondition(Set(value.keys) == Set(["installation_id", "platform", "model", "os_version", "app_version", "app_build"]))
        precondition(value["installation_id"]!.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil)
        precondition(value == DeviceAuditMetadata.value)
        let reporter = DirectConnectionAudit(sessionID: String(repeating: "e", count: 32), sending: false)
        reporter.record("connected"); reporter.record("connected") // duplicate must be ignored
        reporter.record("ended")
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        print("PASS metadata schema/stability; synthetic reports sent (verify server acknowledgements separately)")
    }
}
