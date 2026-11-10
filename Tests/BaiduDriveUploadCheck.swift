import Foundation
import CryptoKit

final class DriveFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var hashes: [String] = []
    static var parts = 0
    static var bytes = 0
    static var mode = "normal"
    static let name = "课程·2026110630.mp4"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 65536)
        while true { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
        return data
    }
    override func startLoading() {
        let url = request.url!, query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let params = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        precondition(["pan.baidu.com", "d.pcs.baidu.com"].contains(url.host!))
        precondition(params["access_token"] == "fixture+token=only")
        var result: [String: Any] = [:]
        if params["method"] == "precreate" {
            let body = requestBody()
            let fields = URLComponents(string: "?" + String(decoding: body, as: UTF8.self))!.queryItems!
            let form = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
            precondition(form["path"] == "/课程/" + Self.name && form["rtype"] == "0")
            precondition(form["size"] == String(4 * 1024 * 1024 + 17))
            result = Self.mode == "conflict" ? ["errno": -8] : ["errno": 0, "uploadid": "fixture-upload", "block_list": [0, 1], "return_type": 1]
                    if Self.mode == "rapid" { result = ["errno": 0, "return_type": 2, "size": 4 * 1024 * 1024 + 17, "path": "/课程/" + Self.name] }
            if Self.mode == "unverified-rapid" { result = ["errno": 0, "return_type": 2] }
        } else if params["method"] == "upload" {
            precondition(url.host == "d.pcs.baidu.com")
            let index = Int(params["partseq"]!)!, boundary = request.value(forHTTPHeaderField: "Content-Type")!.components(separatedBy: "boundary=").last!
            let body = requestBody(), start = body.range(of: Data("\r\n\r\n".utf8))!.upperBound
            let end = body.range(of: Data("\r\n--\(boundary)--\r\n".utf8), options: .backwards)!.lowerBound
            let part = body.subdata(in: start..<end)
            precondition(part.count <= 4 * 1024 * 1024)
            let digest = Insecure.MD5.hash(data: part).map { String(format: "%02x", $0) }.joined()
            precondition(digest == Self.hashes[index]); Self.parts += 1; Self.bytes += part.count
            result = ["errno": 0, "md5": Self.mode == "bad-md5" ? "corrupted" : digest]
        } else if params["method"] == "create" {
            precondition(Self.parts == 2 && Self.bytes == 4 * 1024 * 1024 + 17)
            result = ["errno": 0, "size": Self.bytes, "path": "/课程/" + Self.name]
        } else { preconditionFailure("Unexpected network operation") }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result)); client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum BaiduDriveUploadCheck {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DriveFixtureProtocol.self]
        BaiduTransport.session = URLSession(configuration: config)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("touping-baidu-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(DriveFixtureProtocol.name)
        try Data(repeating: 0x5a, count: 4 * 1024 * 1024 + 17).write(to: file)
        DriveFixtureProtocol.hashes = try BaiduTransport.hashes(file).1
        try await BaiduTransport.upload(file, directory: "/课程", token: "fixture+token=only")
        precondition(FileManager.default.fileExists(atPath: file.path))
        DriveFixtureProtocol.mode = "rapid"
        try await BaiduTransport.upload(file, directory: "/课程", token: "fixture+token=only")
        for mode in ["conflict", "bad-md5", "unverified-rapid"] {
            DriveFixtureProtocol.mode = mode; DriveFixtureProtocol.parts = 0; DriveFixtureProtocol.bytes = 0
            do { try await BaiduTransport.upload(file, directory: "/课程", token: "fixture+token=only"); preconditionFailure("Must reject \(mode)") } catch {}
            precondition(FileManager.default.fileExists(atPath: file.path))
        }
        let stamp = try BaiduTransport.localStamp(file)
        try Data("changed after upload".utf8).write(to: file)
        do { try BaiduTransport.removeUploadedFile(file, matching: stamp); preconditionFailure("Changed file must survive") } catch {}
        precondition(FileManager.default.fileExists(atPath: file.path))
        let current = try BaiduTransport.localStamp(file)
        try BaiduTransport.removeUploadedFile(file, matching: current)
        precondition(!FileManager.default.fileExists(atPath: file.path))
        print("PASS deletion only for unchanged local file; direct-to-Baidu hosts, unchanged unified name, 4MiB bounded multipart slices, MD5 verification, no overwrite and retained local file on failure")
    }
}
