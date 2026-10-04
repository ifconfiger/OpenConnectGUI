import Foundation

enum ProfileStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenConnectGUI", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("profiles.json") }

    static func load() throws -> [VPNProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([VPNProfile].self, from: Data(contentsOf: file))
    }

    static func save(_ profiles: [VPNProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
