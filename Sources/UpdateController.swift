import AppKit
import Foundation
import Security

/// Keeps the app current from GitHub Releases, tagged `main-vX.Y.Z`. A newer release's dmg is
/// downloaded in the background and the app inside is only accepted if it is this app, at that
/// version, signed with Developer ID by the same team as the running copy. The verified app then
/// replaces this one and relaunches once nothing would be interrupted, or when the app quits.
@MainActor
final class UpdateController: ObservableObject {
    static let repo = "ifconfiger/OpenConnectGUI"
    private static let checkInterval: TimeInterval = 6 * 3600
    private static let lastCheckKey = "lastUpdateCheck"

    @Published private(set) var isChecking = false
    private var staged: (version: String, app: URL, work: URL)?
    private var installing = false
    private var lastIdle = false

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.installOnQuit() }
        }
    }

    /// Version from Info.plist; the updater compares marketing versions like the release tags.
    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Called every couple of seconds. `idle` means no tunnel, request or pending reconnect.
    func tick(idle: Bool) {
        lastIdle = idle
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        if !isChecking, Date().timeIntervalSince(last) >= Self.checkInterval {
            Task { await check(userInitiated: false, idle: idle) }
        }
        // Relaunching with the main window open could discard edits on screen.
        guard idle, !NSApp.windows.contains(where: { $0.isVisible && $0.title == "OpenConnect GUI" })
        else { return }
        installStaged(relaunch: true)
    }

    func checkForUpdates(idle: Bool) {
        Task { await check(userInitiated: true, idle: idle) }
    }

    private func check(userInitiated: Bool, idle: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let release = try await Self.fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            let current = Self.currentVersion ?? "0"
            guard Self.isNewer(release.version, than: current) else {
                if userInitiated {
                    alert(String(localized: "You're up to date"),
                          String(localized: "OpenConnect GUI \(current) is the latest version."))
                }
                return
            }
            guard Self.canReplaceRunningApp else { throw UpdateError.notInstallable }
            if staged?.version != release.version { try await stage(release) }
            guard userInitiated else { return }
            let prompt = NSAlert()
            prompt.messageText = String(localized: "OpenConnect GUI \(release.version) is ready to install")
            if idle {
                prompt.informativeText = String(localized: "You have version \(current).")
                prompt.addButton(withTitle: String(localized: "Install and Relaunch"))
                prompt.addButton(withTitle: String(localized: "Later"))
                if prompt.runModal() == .alertFirstButtonReturn { installStaged(relaunch: true) }
            } else {
                prompt.informativeText = String(localized: "It installs automatically once the VPN is disconnected and the main window is closed, or when you quit the app.")
                prompt.runModal()
            }
        } catch UpdateError.notInstallable {
            guard userInitiated else { return }
            alert(String(localized: "Couldn't install the update"), UpdateError.notInstallable.localizedDescription)
            NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
        } catch {
            if userInitiated { alert(String(localized: "Couldn't check for updates"), error.localizedDescription) }
        }
    }

    // MARK: - GitHub

    struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }

        var version: String {
            tagName.replacingOccurrences(of: "main-v", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        }

        var dmg: Asset? { assets.first { $0.name.hasSuffix(".dmg") } }
    }

    private static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!,
                                 timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenConnectGUI/\(currentVersion ?? "dev")", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "OpenConnectGUI", code: 5, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "GitHub returned HTTP \(code).")
            ])
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Numeric comparison of dotted versions: 0.10.0 > 0.9.1
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Download and verify

    enum UpdateError: LocalizedError {
        case noPackage, download, extract, invalidBundle, signature, notInstallable

        var errorDescription: String? {
            switch self {
            case .noPackage: String(localized: "This release has no app package to install.")
            case .download: String(localized: "The download failed.")
            case .extract: String(localized: "The downloaded package couldn't be unpacked.")
            case .invalidBundle: String(localized: "The downloaded app doesn't match this app's identity or version.")
            case .signature: String(localized: "The downloaded app isn't signed by the same developer, so it was not installed.")
            case .notInstallable: String(localized: "OpenConnect GUI can't replace itself in its current location. Download the new version from GitHub and move it to Applications.")
            }
        }
    }

    private func stage(_ release: Release) async throws {
        guard let asset = release.dmg else { throw UpdateError.noPackage }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenConnectGUI-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let (download, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
            let dmg = work.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at: download, to: dmg)
            let version = release.version
            let app = try await Task.detached { try Self.extractAndVerify(dmg, in: work, version: version) }.value
            if let previous = staged { try? FileManager.default.removeItem(at: previous.work) }
            staged = (version, app, work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Copy the app out of the dmg and make sure it is this app, at the expected version,
    /// signed with Developer ID by the same team as the running copy.
    private nonisolated static func extractAndVerify(_ dmg: URL, in work: URL, version: String) throws -> URL {
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                       "-mountpoint", mount.path]) else { throw UpdateError.extract }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let source = try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.extract }
        let app = work.appendingPathComponent(source.lastPathComponent)
        guard run("/usr/bin/ditto", [source.path, app.path]) else { throw UpdateError.extract }

        guard let bundle = Bundle(url: app), let identifier = Bundle.main.bundleIdentifier,
              bundle.bundleIdentifier == identifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version
        else { throw UpdateError.invalidBundle }

        // Builds without a team (ad-hoc) can't vouch for an update.
        guard let team = teamIdentifier(of: Bundle.main.bundleURL) else { throw UpdateError.signature }
        let requirementText = "identifier \"\(identifier)\" and anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(team)\""
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        else { throw UpdateError.signature }
        return app
    }

    private nonisolated static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Install

    /// Translocated (quarantined, run in place) or read-only locations can't be updated in place.
    private static var canReplaceRunningApp: Bool {
        let current = Bundle.main.bundleURL
        let fm = FileManager.default
        return !current.path.contains("/AppTranslocation/") &&
            fm.isWritableFile(atPath: current.deletingLastPathComponent().path) &&
            fm.isWritableFile(atPath: current.path)
    }

    private func installOnQuit() {
        guard lastIdle else { return }
        installStaged(relaunch: false)
    }

    /// A detached script waits for this process to exit, swaps the bundles (rolling back on
    /// failure) and, when relaunching, opens the result.
    private func installStaged(relaunch: Bool) {
        guard !installing, let staged, Self.canReplaceRunningApp else { return }
        let current = Bundle.main.bundleURL
        let destination = current.deletingLastPathComponent().appendingPathComponent(staged.app.lastPathComponent)
        let script = staged.work.appendingPathComponent("install.sh")
        do {
            try """
            #!/bin/sh
            PID="$1"; OLD="$2"; NEW="$3"; DEST="$4"; WORK="$5"; RELAUNCH="$6"
            while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
            STAGE="$DEST.update-new"; BACKUP="$OLD.update-old"
            rm -rf "$STAGE" "$BACKUP"
            if ! ditto "$NEW" "$STAGE"; then rm -rf "$STAGE"; [ "$RELAUNCH" = 1 ] && open "$OLD"; exit 1; fi
            if ! mv "$OLD" "$BACKUP"; then rm -rf "$STAGE"; [ "$RELAUNCH" = 1 ] && open "$OLD"; exit 1; fi
            [ "$DEST" != "$OLD" ] && rm -rf "$DEST"
            if mv "$STAGE" "$DEST"; then
              rm -rf "$BACKUP"
            else
              rm -rf "$STAGE"; mv "$BACKUP" "$OLD"; DEST="$OLD"
            fi
            [ "$RELAUNCH" = 1 ] && open "$DEST"
            rm -rf "$WORK"
            """.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), current.path,
                                 staged.app.path, destination.path, staged.work.path, relaunch ? "1" : "0"]
            try process.run()
        } catch { return }
        installing = true
        if relaunch { NSApp.terminate(nil) }
    }
}
