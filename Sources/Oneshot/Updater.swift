import Foundation
import AppKit

/// Checks GitHub releases and installs updates in place. Every release is signed
/// with the same certificate, so macOS keeps the app's permissions.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "brunoqgalvao/oneshot"

    @Published private(set) var available: String?
    @Published private(set) var installing = false
    private var downloadURL: URL?
    private var timer: Timer?

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check() }
        }
    }

    func check() async {
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let url = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if Self.isNewer(version, than: current) {
            available = version
            downloadURL = url
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Downloads the new build, swaps it in place and relaunches.
    func install() {
        guard let url = downloadURL, !installing else { return }
        installing = true
        Task {
            do {
                let (tmp, _) = try await URLSession.shared.download(from: url)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let zip = dir.appendingPathComponent("Oneshot.zip")
                try FileManager.default.moveItem(at: tmp, to: zip)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zip.path, dir.path]
                try unzip.run(); unzip.waitUntilExit()
                let fresh = dir.appendingPathComponent("Oneshot.app")
                guard FileManager.default.fileExists(atPath: fresh.path) else { throw URLError(.cannotDecodeContentData) }
                let target = Bundle.main.bundlePath
                let pid = ProcessInfo.processInfo.processIdentifier
                // Wait for this process to quit, swap bundles, relaunch.
                let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /bin/rm -rf \"$1\" && /bin/mv \"$2\" \"$1\" && /usr/bin/xattr -dr com.apple.quarantine \"$1\"; /usr/bin/open \"$1\""
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script, "sh", target, fresh.path]
                try p.run()
                NSApp.terminate(nil)
            } catch {
                installing = false
                NSLog("Oneshot update failed: \(error)")
            }
        }
    }
}
