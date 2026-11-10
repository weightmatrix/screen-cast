import Foundation

@main enum MediaPathCheck {
    static func main() {
        func host(_ address: String, _ type: String = "host") -> [String: Any] { ["address": address, "candidateType": type] }
        let local = host("192.168.1.3"), remote = host("192.168.1.8")
        let wifi = MediaPath.Interface(name: "en0", detail: "Wi-Fi", sameSubnet: true)
        let usb = MediaPath.Interface(name: "en7", detail: "iPhone USB", deviceUSB: true, sameSubnet: true)
        precondition(MediaPath.route(local: local, remote: remote, interface: wifi).contains("局域网"))
        precondition(MediaPath.route(local: local, remote: remote, interface: usb).contains("USB设备"))
        precondition(!MediaPath.route(local: local, remote: remote, interface: nil).contains("USB设备"))
        precondition(MediaPath.route(local: local, remote: remote, interface: .init(name: "utun1", detail: "VPN", tunnel: true, sameSubnet: true)).contains("VPN"))
        precondition(MediaPath.route(local: local, remote: host("8.8.8.8", "srflx"), interface: usb).contains("公网地址"), "USB local interface must not label internet as USB direct")
        precondition(MediaPath.route(local: local, remote: host("peer.local"), interface: nil).contains("未确认"))
        precondition(MediaPath.route(local: local, remote: host("1.2.3.4", "relay"), interface: nil) == "中继路径")
        precondition(MediaPath.route(local: host("127.0.0.1"), remote: host("127.0.0.1"), interface: nil) == "本机回环直连")
        precondition(MediaPath.bytes("fe80::1%en0") == MediaPath.bytes("fe80::1"))
        precondition(MediaPath.nonPublic("2001:4860:4860::8888") == false)
        precondition(MediaPath.nonPublic("fd00::1") == true && MediaPath.nonPublic("169.254.1.2") == true)
        precondition(MediaPath.nonPublic("::ffff:192.168.1.3") == true)
        precondition(MediaPath.nonPublic("host.local") == nil && MediaPath.bytes("999.2.3.4") == nil)
        precondition(MediaPath.interface(local: host("127.0.0.1"), remote: host("127.0.0.2"))?.name == "lo0")
        let old = Data(#"{"id":"fixture","device":"old","route":"old","localEndpoint":"x","remoteEndpoint":"y"}"#.utf8)
        let decoded = try! JSONDecoder().decode(PeerDiagnostic.self, from: old)
        precondition(decoded.networkInterface == nil && decoded.signals == nil)
        precondition(decoded.source == nil && decoded.nickname == nil)
        var bridge = decoded; bridge.source = "公网网页"; bridge.nickname = "示例昵称"
        let bridged = try! JSONDecoder().decode(PeerDiagnostic.self, from: JSONEncoder().encode(bridge))
        precondition(bridged.source == "公网网页" && bridged.nickname == "示例昵称")
        precondition(Set(ConnectionOrigin.allCases.map(\.title)) == Set(["公网网页","局域网网页","app公网直连","app公网邀请码","app局域网直连","app局域网邀请码"]))
        precondition(ConnectionOrigin(rawValue: "invented") == nil)
        precondition(MediaPath.connectionLabel(route: "局域网直连（同子网）", interface: "Wi-Fi · en0") == "Wi-Fi局域网")
        precondition(MediaPath.connectionLabel(route: "局域网直连（同子网）", interface: "Ethernet") == "有线局域网")
        precondition(MediaPath.connectionLabel(route: "USB设备网络直连", interface: "iPhone USB") == "USB电缆")
        precondition(MediaPath.connectionLabel(route: "本机回环直连", interface: "lo0") == "本机回环")
        precondition(MediaPath.connectionLabel(route: "公网地址直连（可能同网回环）", interface: "Wi-Fi") == "公网直连")
        precondition(MediaPath.connectionLabel(route: "内网直连（局域网/VPN待确认）", interface: "") == "内网（介质未确认）")
        precondition(MediaPath.connectionLabel(route: "直连（地址隐藏或接口未确认）", interface: "") == "连接方式待确认")
        print("PASS actual-pair routes, USB evidence, VPN/public/mDNS uncertainty, interface matching, IPv6 and legacy diagnostics")
    }
}
