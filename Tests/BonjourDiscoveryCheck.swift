import Foundation
import Network

@main enum BonjourDiscoveryCheck {
    @MainActor static func main() async throws {
        let code = "36024681" // Dedicated synthetic fixture, not a user matching code.
        let discovery = BonjourDiscovery()
        let listener = try NWListener(using: .tcp, on: .any)
        listener.service = NWListener.Service(name: LocalBonjour.name(code: code, port: 0), type: LocalBonjour.type)
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .main); discovery.start()
        defer { listener.cancel(); discovery.stop() }
        precondition(!LocalBonjour.name(code: code, port: 0).contains(code))
        for _ in 0..<80 {
            if let endpoint = discovery.find(code: code), endpoint.port == listener.port?.rawValue {
                precondition(discovery.find(code: "00000000") == nil)
                print("PASS Bonjour publication/resolution and matching-code lookup; no raw code in service name")
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        print("FAIL Bonjour discovery timed out; inspect local network permission and mDNS")
        exit(1)
    }
}
