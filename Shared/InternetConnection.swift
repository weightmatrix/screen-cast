import Foundation
import Network
import Security
import CryptoKit
import WebRTC

enum ConnectionMode: String, CaseIterable, Identifiable {
    case localIP = "ip", localCode = "code", internetIP = "wanIP", internetCode = "wanCode"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .localIP: return "局域 IP 直连"
        case .localCode: return "局域匹配码"
        case .internetIP: return "广域网 IP 直连"
        case .internetCode: return "广域网匹配码"
        }
    }
}

enum InternetSettings {
    static let signalingURL = URL(string: "wss://zhibenwang.com/touping/signal")!
    static let stunURL = "stun:49.233.174.254:3478"
    static func room(_ code: String) -> String { SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func tlsParameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let key = Data(SHA256.hash(data: Data(("touping-tls-v1:" + code).utf8)))
        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("touping-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secret as __DispatchData, identity as __DispatchData)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }
}
