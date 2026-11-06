import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Security
import SwiftUI

private enum DriveError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum BaiduTransport {
    static var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 180
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config)
    }()
    static func form(_ values: [String: String]) -> Data {
        var parts = URLComponents(); parts.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // application/x-www-form-urlencoded: a literal plus must remain encoded.
        return Data((parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    static func request(_ url: URL, form values: [String: String]? = nil, json: [String: Any]? = nil, multipart: Data? = nil, boundary: String = "") async throws -> [String: Any] {
        try Task.checkCancellation()
        var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalCacheData
        if let values { request.httpMethod = "POST"; request.httpBody = form(values); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        if let json { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: json); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let multipart { request.httpMethod = "POST"; request.httpBody = multipart; request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type") }
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw DriveError.message("网络请求失败，请检查连接后重试") }
        guard data.count <= 4 * 1024 * 1024, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DriveError.message("百度网盘服务暂不可用，请稍后重试") }
        if let code = result["errno"] as? Int, code != 0 { throw DriveError.message("百度网盘请求失败（\(code)），本地文件已保留") }
        if result["error"] != nil { throw DriveError.message("授权未完成或已失效，请重新登录百度网盘") }
        return result
    }
    static func url(_ path: String, token: String, parameters: [String: String] = [:], upload: Bool = false) -> URL {
        var url = URLComponents(string: (upload ? "https://d.pcs.baidu.com" : "https://pan.baidu.com") + path)!
        var parameters = parameters; parameters["access_token"] = token
        url.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B"); return url.url!
    }
    static func user(_ token: String) async throws -> (String, String) {
        let info = try await request(url("/rest/2.0/xpan/nas", token: token, parameters: ["method": "uinfo"]))
        guard let number = info["uk"] as? NSNumber else { throw DriveError.message("无法确认百度网盘账户，请重新授权") }
        return (number.stringValue, info["netdisk_name"] as? String ?? info["baidu_name"] as? String ?? "百度网盘用户")
    }
    static func hashes(_ file: URL) throws -> (Int64, [String]) {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var size: Int64 = 0, list: [String] = []
        while let part = try handle.read(upToCount: 4 * 1024 * 1024), !part.isEmpty {
            size += Int64(part.count)
            guard size <= 4 * 1024 * 1024 * 1024 else { throw DriveError.message("当前上传最多支持4GB单文件，本地录课已保留") }
            list.append(Insecure.MD5.hash(data: part).map { String(format: "%02x", $0) }.joined())
        }
        guard size > 0 else { throw DriveError.message("录课文件为空") }; return (size, list)
    }
    static func upload(_ file: URL, directory: String, token: String) async throws {
        let (size, hashes) = try await Task.detached(priority: .utility) { try self.hashes(file) }.value
        let remote = (directory == "/" ? "" : directory) + "/" + file.lastPathComponent
        let blockList = String(data: try JSONSerialization.data(withJSONObject: hashes), encoding: .utf8)!
        var values = ["path": remote, "size": String(size), "isdir": "0", "block_list": blockList, "rtype": "0", "autoinit": "1"]
        let pre = try await request(url("/rest/2.0/xpan/file", token: token, parameters: ["method": "precreate"]), form: values)
        if pre["return_type"] as? Int == 2 { return }
        guard let uploadID = pre["uploadid"] as? String, !uploadID.isEmpty,
              let missing = pre["block_list"] as? [Int], missing.allSatisfy({ hashes.indices.contains($0) }) else { throw DriveError.message("百度预上传响应无效，本地文件已保留") }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        for index in missing {
            try Task.checkCancellation(); try handle.seek(toOffset: UInt64(index) * 4 * 1024 * 1024)
            guard let bytes = try handle.read(upToCount: 4 * 1024 * 1024), !bytes.isEmpty,
                  Insecure.MD5.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hashes[index] else { throw DriveError.message("录课文件发生变化，已暂停上传") }
            let boundary = "Touping-" + UUID().uuidString
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"part\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
            body.append(bytes); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            let part = try await request(url("/rest/2.0/pcs/superfile2", token: token, parameters: ["method": "upload", "type": "tmpfile", "path": remote, "uploadid": uploadID, "partseq": String(index)], upload: true), multipart: body, boundary: boundary)
            guard part["md5"] as? String == hashes[index] else { throw DriveError.message("百度分片校验未通过，本地文件已保留") }
        }
        values["uploadid"] = uploadID; values.removeValue(forKey: "autoinit")
        let result = try await request(url("/rest/2.0/xpan/file", token: token, parameters: ["method": "create"]), form: values)
        guard result["size"] as? Int64 == size, result["path"] as? String == remote else { throw DriveError.message("网盘文件校验未通过，请保留本地录课并检查网盘") }
    }
}

@MainActor final class BaiduDrive: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = BaiduDrive()
    static let callback = "https://zhibenwang.com/touping/baidu/callback"
    @Published var enabled = UserDefaults.standard.bool(forKey: "lesson.baiduEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "lesson.baiduEnabled"); if enabled { startUploads() } else { cancelUploads() } }
    }
    @Published private(set) var status = "未登录百度网盘"
    @Published private(set) var accountName = ""
    @Published private(set) var pendingCount = 0
    @Published private(set) var authenticating = false
    @Published private(set) var directories: [(path: String, name: String)] = []
    @Published var browserPath = "/"
    @Published var destination = UserDefaults.standard.string(forKey: "lesson.baiduDirectory") ?? "/" {
        didSet { UserDefaults.standard.set(destination, forKey: "lesson.baiduDirectory") }
    }
    private struct Credentials: Codable { var access: String; var refresh: String; var expires: Date; var account: String; var name: String }
    private struct Job: Codable { var file: String; var account: String; var directory: String; var attempts = 0 }
    private var credentials: Credentials?
    private var jobs: [Job] = []
    private var webSession: ASWebAuthenticationSession?
    private var worker: Task<Void, Never>?
    private var workerID = UUID()
    private var authID = UUID()
    private var refreshWork: Task<String, Error>?
    private var folderSink: AnyCancellable?
    private let keyQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Han.touping.baidu.oauth", kSecAttrAccount as String: "user"]
    var loggedIn: Bool { credentials != nil }
    override init() {
        super.init()
        var query = keyQuery; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var stored: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &stored) == errSecSuccess, let data = stored as? Data, let saved = try? JSONDecoder().decode(Credentials.self, from: data) {
            credentials = saved; accountName = saved.name; status = "已保存百度网盘授权"
        }
        folderSink = RecordingFolderPreferences.shared.$folder.receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor in self?.cancelUploads(); self?.loadQueue(); self?.startUploads() }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
    private func broker(_ action: String, _ payload: [String: Any]) async throws -> [String: Any] {
        try await BaiduTransport.request(URL(string: "https://zhibenwang.com/touping/baidu/" + action)!, json: payload)
    }
    private func save(_ value: Credentials) throws {
        let data = try JSONEncoder().encode(value)
        let update = SecItemUpdate(keyQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = keyQuery; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw DriveError.message("无法安全保存授权，请重试") }
        } else if update != errSecSuccess { throw DriveError.message("无法更新安全授权，请重试") }
        credentials = value; accountName = value.name
    }
    private func token() async throws -> String {
        guard let value = credentials else { throw DriveError.message("请先登录百度网盘") }
        if value.expires.timeIntervalSinceNow > 300 { return value.access }
        if let refreshWork { return try await refreshWork.value }
        let epoch = authID
        let work = Task { () throws -> String in
            let response = try await broker("refresh", ["refresh_token": value.refresh])
            guard authID == epoch else { throw CancellationError() }
            guard let access = response["access_token"] as? String else { throw DriveError.message("授权已失效，请重新登录百度网盘") }
            try save(Credentials(access: access, refresh: response["refresh_token"] as? String ?? value.refresh,
                expires: Date().addingTimeInterval(response["expires_in"] as? Double ?? 3600), account: value.account, name: value.name))
            return access
        }
        refreshWork = work
        defer { if authID == epoch { refreshWork = nil } }
        return try await work.value
    }

    func login(qr: Bool) {
        guard !authenticating else { return }; cancelUploads(); authenticating = true
        authID = UUID(); refreshWork?.cancel(); refreshWork = nil; let epoch = authID
        Task {
            defer { authenticating = false; startUploads() }
            do {
                let flow = try await broker("start", ["qr": qr])
                guard let state = flow["state"] as? String, let claim = flow["claim"] as? String,
                      let text = flow["authorize_url"] as? String, let url = URL(string: text), url.scheme == "https", url.host == "openapi.baidu.com" else { throw DriveError.message("百度授权入口无效") }
                let returned: URL = try await withCheckedThrowingContinuation { continuation in
                    webSession = ASWebAuthenticationSession(url: url, callbackURLScheme: "touping-baidu") { url, error in
                        if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: DriveError.message("百度网盘登录已取消")) }
                    }
                    webSession?.presentationContextProvider = self; webSession?.prefersEphemeralWebBrowserSession = false
                    if webSession?.start() != true { continuation.resume(throwing: DriveError.message("无法打开百度授权窗口")); webSession = nil }
                }
                webSession = nil
                guard URLComponents(url: returned, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value == state else { throw DriveError.message("授权校验失败，请重试") }
                let response = try await broker("complete", ["state": state, "claim": claim])
                guard let access = response["access_token"] as? String, let refresh = response["refresh_token"] as? String else { throw DriveError.message("百度未返回完整授权，请重新登录") }
                let (account, name) = try await BaiduTransport.user(access)
                guard authID == epoch else { throw CancellationError() }
                if credentials?.account != account { enabled = false; destination = "/" }
                try save(Credentials(access: access, refresh: refresh, expires: Date().addingTimeInterval(response["expires_in"] as? Double ?? 3600), account: account, name: name))
                status = "已登录：" + name; startUploads()
            } catch { status = error.localizedDescription }
        }
    }
    func logout() { enabled = false; authID = UUID(); refreshWork?.cancel(); refreshWork = nil; cancelUploads(); webSession?.cancel(); webSession = nil; SecItemDelete(keyQuery as CFDictionary); credentials = nil; accountName = ""; status = "已退出百度网盘，待传录课仍保留在本机" }
    func browse(_ path: String) {
        let epoch = authID
        Task {
            do {
                let access = try await token()
                let result = try await BaiduTransport.request(BaiduTransport.url("/rest/2.0/xpan/file", token: access, parameters: ["method": "list", "dir": path, "folder": "1", "order": "name", "start": "0", "limit": "1000"]))
                guard authID == epoch else { return }
                directories = (result["list"] as? [[String: Any]] ?? []).compactMap { entry in
                    guard entry["isdir"] as? Int == 1, let path = entry["path"] as? String, let name = entry["server_filename"] as? String else { return nil }; return (path, name)
                }
                browserPath = path; status = "已读取网盘目录"
            } catch { status = error.localizedDescription }
        }
    }
    func createDirectory(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != "..", name.count <= 80 else { status = "请填写有效的新目录名字"; return }
        Task {
            do {
                let access = try await token(), path = (browserPath == "/" ? "" : browserPath) + "/" + name
                _ = try await BaiduTransport.request(BaiduTransport.url("/rest/2.0/xpan/file", token: access, parameters: ["method": "create"]), form: ["path": path, "isdir": "1", "size": "0", "block_list": "[]", "rtype": "0"])
                browse(path)
            } catch { status = error.localizedDescription }
        }
    }
    private var queueURL: URL? { RecordingFolderPreferences.shared.folder?.appendingPathComponent("tmp", isDirectory: true).appendingPathComponent("baidu-uploads.json") }
    private func loadQueue() {
        guard let root = RecordingFolderPreferences.shared.folder, let url = queueURL else { return }
        do {
            _ = try RecordingFolderPreferences.cacheDirectory(in: root)
            if FileManager.default.fileExists(atPath: url.path) {
                let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                guard info.isSymbolicLink != true, (info.fileSize ?? 0) <= 262144 else { throw DriveError.message("待传记录无效") }
                let data = try Data(contentsOf: url); guard data.count <= 262144 else { throw DriveError.message("待传记录过大，请保留本地文件并联系支持") }
                let loaded = try JSONDecoder().decode([Job].self, from: data)
                guard loaded.count <= 64, loaded.allSatisfy({ !$0.file.contains("/") && !$0.file.contains("\\") && $0.file.hasSuffix(".mp4") && $0.directory.hasPrefix("/") && $0.directory.utf8.count <= 2048 && $0.file.utf8.count <= 240 && (0...3).contains($0.attempts) }) else { throw DriveError.message("待传记录无效，本地文件已保留") }
                jobs = loaded
            } else { jobs = [] }
            pendingCount = jobs.count
        } catch { status = "无法读取待传记录，本地文件已保留" }
    }
    private func persistQueue() throws {
        guard let root = RecordingFolderPreferences.shared.folder, let url = queueURL else { throw DriveError.message("请先选择本地录课缓存目录") }
        _ = try RecordingFolderPreferences.cacheDirectory(in: root)
        try JSONEncoder().encode(jobs).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path); pendingCount = jobs.count
    }
    func enqueue(_ file: URL) {
        guard enabled else { return }
        guard let credentials else { status = "录课已在本机保存，请先登录百度网盘"; return }
        guard destination.hasPrefix("/"), destination.utf8.count <= 2048, jobs.count < 64, let root = RecordingFolderPreferences.shared.folder,
              file.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else { status = "待传队列已满或目录已变，录课仍在本机"; return }
        guard !jobs.contains(where: { $0.file == file.lastPathComponent && $0.account == credentials.account }) else { return }
        jobs.append(Job(file: file.lastPathComponent, account: credentials.account, directory: destination))
        do { try persistQueue(); startUploads() } catch { status = "待传状态保存失败，录课仍在本机" }
    }
    private func cancelUploads() { workerID = UUID(); worker?.cancel(); worker = nil }
    func clearPendingUploads() {
        cancelUploads(); let previous = jobs; jobs = []
        do { try persistQueue(); status = "已清除待传记录，本地录像和网盘文件均保留" }
        catch { jobs = previous; pendingCount = jobs.count; status = "待传记录未能清除，请检查本地目录权限" }
    }
    func retryUploads() { for index in jobs.indices { jobs[index].attempts = 0 }; do { try persistQueue(); startUploads() } catch { status = "无法保存待传状态" } }
    private func startUploads() {
        guard worker == nil, !authenticating, enabled, credentials != nil, !jobs.isEmpty else { return }
        let id = UUID(); workerID = id
        worker = Task {
            defer { if workerID == id { worker = nil } }
            while !Task.isCancelled, enabled, let job = jobs.first {
                guard job.account == credentials?.account else { status = "待传录课属于另一账户，请登录原账户后继续"; return }
                guard job.attempts < 3, let root = RecordingFolderPreferences.shared.folder else { status = "上传已暂停，请检查网络或目录后点击重试"; return }
                do {
                    let file = root.appendingPathComponent(job.file)
                    let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                    guard values.isSymbolicLink != true, values.isRegularFile == true else { throw DriveError.message("本地待传文件不可用，已暂停") }
                    let access = try await token(); status = "正在上传：" + job.file
                    try await BaiduTransport.upload(file, directory: job.directory, token: access)
                    try Task.checkCancellation(); guard workerID == id else { return }
                    jobs.removeFirst()
                    do { try persistQueue() } catch { jobs.insert(job, at: 0); throw DriveError.message("上传完成但本地待传状态未能保存，请检查磁盘") }
                    status = "百度网盘已保存：" + job.file
                } catch {
                    guard workerID == id, !Task.isCancelled, !jobs.isEmpty, jobs[0].file == job.file else { return }
                    jobs[0].attempts += 1; try? persistQueue(); status = error.localizedDescription
                    if jobs[0].attempts < 3 { try? await Task.sleep(nanoseconds: UInt64(jobs[0].attempts * 2) * 1_000_000_000) }
                    else { return }
                }
            }
        }
    }
}

struct BaiduDriveSettings: View {
    @ObservedObject private var drive = BaiduDrive.shared
    @State private var choosing = false
    @State private var confirmClear = false
    @State private var newDirectory = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("登录百度网盘") { drive.login(qr: false) }.disabled(drive.authenticating)
                Button("二维码登录") { drive.login(qr: true) }.disabled(drive.authenticating)
                if drive.loggedIn { Button("退出登录") { drive.logout() } }
            }
            Toggle("录课分段完成后上传百度网盘", isOn: $drive.enabled).disabled(!drive.loggedIn)
            HStack { Text("网盘目录：" + drive.destination).lineLimit(2); Button("选择网盘目录") { choosing = true; drive.browse(drive.destination) }.disabled(!drive.loggedIn) }
            Text(drive.status).font(.caption).foregroundStyle(.secondary)
            if drive.pendingCount > 0 { HStack { Text("待传 \(drive.pendingCount) 个录课文件"); Button("重试上传") { drive.retryUploads() }; Button("清除待传") { confirmClear = true } } }
            Text("录课从本机直接上传百度网盘，不经过投屏服务器。每10分钟完成一段后上传，原文件保留；授权有效期内自动续期。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("清除待传记录？本地录像和网盘文件均保留。", isPresented: $confirmClear) {
            Button("清除待传记录", role: .destructive) { drive.clearPendingUploads() }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $choosing) {
            VStack(alignment: .leading, spacing: 14) {
                Text("选择网盘目标目录").font(.title2)
                Text(drive.browserPath).textSelection(.enabled)
                Button("上一级") { drive.browse((drive.browserPath as NSString).deletingLastPathComponent.isEmpty ? "/" : (drive.browserPath as NSString).deletingLastPathComponent) }
                List(drive.directories, id: \.path) { item in Button { drive.browse(item.path) } label: { Label(item.name, systemImage: "folder") } }.frame(minHeight: 220)
                HStack { TextField("新建目录名字", text: $newDirectory); Button("新建目录") { drive.createDirectory(newDirectory) } }
                Text(drive.status).font(.caption).foregroundStyle(.secondary)
                HStack { Button("取消") { choosing = false }; Spacer(); Button("保存到此目录") { drive.destination = drive.browserPath; choosing = false } }
            }.padding(28).frame(width: 540, height: 460)
        }
    }
}
