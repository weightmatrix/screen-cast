import Foundation

/// Visible identity follows the installed app version on both native platforms.
enum AppPresentation {
    static var title: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "李知本·投屏管理·\(version)（\(build)）"
    }
    static let receiveWorkbench = "接受工作台"
}
