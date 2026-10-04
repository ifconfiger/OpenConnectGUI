import Foundation

enum MobileProfileStore {
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profiles.json")
    }

    static func load() throws -> [VPNProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([VPNProfile].self, from: Data(contentsOf: file))
    }

    static func save(_ profiles: [VPNProfile]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(profiles).write(to: file, options: .atomic)
    }
}
