import AppKit
import Foundation

struct OpenAppAction: MacAction {
    let name = "open_app"
    let description = "Open a macOS application by name (e.g. Safari, Notes, Terminal)."
    let parametersSchema: [String: String] = [
        "app": "Application name (without .app), e.g. \"Safari\" or \"Visual Studio Code\""
    ]

    func execute(args: [String: Any]) async -> MacActionResult {
        guard let appName = (args["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !appName.isEmpty
        else {
            return .failure(L("缺少应用名称", "Missing app name"))
        }

        // NSWorkspace.fullPath(forApplication:) handles many casings + locales.
        let workspace = NSWorkspace.shared
        let candidate = workspace.fullPath(forApplication: appName)
            ?? workspace.fullPath(forApplication: appName.capitalized)
        guard let path = candidate else {
            return .failure(L("找不到应用：\(appName)", "App not found: \(appName)"))
        }

        let url = URL(fileURLWithPath: path)
        return await withCheckedContinuation { continuation in
            workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    continuation.resume(returning: .failure(error.localizedDescription))
                } else {
                    continuation.resume(returning: .ok(L("已打开 \(appName)", "Opened \(appName)")))
                }
            }
        }
    }
}
