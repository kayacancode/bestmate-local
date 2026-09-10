import Foundation

struct WorkspaceRepository {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("workspace.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.bestmate.local.opensource/LocalWorkspace", isDirectory: true)
    }

    func load() throws -> LocalWorkspaceData {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LocalWorkspaceData() }
        let data = try JSONDecoder().decode(LocalWorkspaceData.self, from: Data(contentsOf: fileURL))
        guard data.schemaVersion == 1 else { throw WorkspaceStorageError.unsupportedVersion }
        return data
    }

    func save(_ value: LocalWorkspaceData) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum WorkspaceStorageError: LocalizedError {
    case unsupportedVersion
    case readOnly
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "This workspace was saved by a newer Bestmate. Its data has not been changed."
        case .readOnly: return "The saved workspace could not be opened. Resolve the storage error before changing it."
        case .invalid(let message): return message
        }
    }
}
