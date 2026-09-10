import Foundation

/// Client for Granola's official public API (`public-api.granola.ai`).
/// Users bring their own key — `grn_…`, created in the Granola app under
/// Settings → Connectors → API keys — so sync no longer depends on the
/// plaintext local cache (which newer Granola installs encrypt).
///
/// Only notes with a generated summary + transcript are returned by the
/// API; a Get on an individual note can 404. Rate limits are 25 requests
/// burst / 5 req/s sustained, so callers fetch transcripts SEQUENTIALLY —
/// the client enforces a small politeness delay after every request and
/// retries once (after 2s) on 429.
struct GranolaApiClient {

    let apiKey: String
    var session: URLSession = .shared

    private static let base = URL(string: "https://public-api.granola.ai/v1")!
    /// Politeness delay after each request. 250ms keeps a sequential loop
    /// comfortably under the 5 req/s sustained limit.
    private static let interRequestDelayNs: UInt64 = 250_000_000

    // MARK: - Public surface

    struct Note: Identifiable, Hashable {
        var id: String { noteId }
        /// Granola note id (`not_…`) — used as the ingest externalId for dedupe.
        let noteId: String
        let title: String
        let ownerName: String?
        let ownerEmail: String?
        let summary: String?
        let createdAt: Date?
    }

    struct Folder: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let parentFolderID: String?
        enum CodingKeys: String, CodingKey { case id, name; case parentFolderID = "parent_folder_id" }

        func path(in folders: [Folder]) -> String {
            let lookup = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var names = [name]
            var parent = parentFolderID
            var seen: Set<String> = [id]
            while let id = parent, seen.insert(id).inserted, let folder = lookup[id] {
                names.insert(folder.name, at: 0)
                parent = folder.parentFolderID
            }
            return names.joined(separator: " / ")
        }
    }

    func listFolders() async throws -> [Folder] {
        var folders: [Folder] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            var components = URLComponents(url: Self.base.appendingPathComponent("folders"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "page_size", value: "30")]
            if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page = try JSONDecoder().decode(FoldersPage.self, from: await get(components.url!))
            folders.append(contentsOf: page.folders)
            cursor = page.hasMore ? page.cursor : nil
            if page.hasMore && (cursor == nil || !seen.insert(cursor!).inserted) { throw ApiError.http(200, "Invalid folder cursor") }
        } while cursor != nil
        return Array(Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
            .sorted { $0.path(in: folders).localizedStandardCompare($1.path(in: folders)) == .orderedAscending }
    }

    private struct FoldersPage: Decodable {
        let folders: [Folder]
        let hasMore: Bool
        let cursor: String?
    }

    enum ApiError: LocalizedError {
        case badKey
        case notFound
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .badKey:
                return "Granola rejected the key — create one in Granola Settings → Connectors → API keys."
            case .notFound:
                return "Granola doesn't have that note (it may not have a summary yet)."
            case .http(let code, _):
                return "Granola could not complete the request (HTTP \(code)). Try again or check your API access."
            }
        }
    }

    /// Pages until completion or the caller’s limit. The legacy sync defaults
    /// to 200 notes; the explicit folder picker uses nil to make Select all complete.
    func listNotes(createdAfter: Date?, folderID: String? = nil, limit: Int? = 200) async throws -> [Note] {
        var out: [Note] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var comps = URLComponents(
                url: Self.base.appendingPathComponent("notes"),
                resolvingAgainstBaseURL: false,
            )!
            var items: [URLQueryItem] = [URLQueryItem(name: "page_size", value: "30")]
            if let folderID { items.append(URLQueryItem(name: "folder_id", value: folderID)) }
            if let createdAfter {
                items.append(URLQueryItem(
                    name: "created_after",
                    value: ISO8601DateFormatter().string(from: createdAfter),
                ))
            }
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            if !items.isEmpty { comps.queryItems = items }
            let data = try await get(comps.url!)
            let page: NotesPage
            do { page = try JSONDecoder().decode(NotesPage.self, from: data) }
            catch { throw ApiError.http(200, "unexpected notes payload: \(error.localizedDescription)") }
            out.append(contentsOf: page.notes.map { $0.toNote() })
            cursor = (page.hasMore ?? false) ? page.cursor : nil
            if page.hasMore == true && (cursor == nil || !seen.insert(cursor!).inserted) { throw ApiError.http(200, "Invalid notes cursor") }
        } while cursor != nil && (limit == nil || out.count < limit!)
        let unique = out.filter { note in seen.insert("note:" + note.id).inserted }
        return limit.map { Array(unique.prefix($0)) } ?? unique
    }

    /// Summary only: private notes and transcripts are not imported implicitly.
    func fetchSummary(noteId: String) async throws -> String {
        guard noteId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw ApiError.notFound }
        let data = try await get(Self.base.appendingPathComponent("notes").appendingPathComponent(noteId))
        let detail = try JSONDecoder().decode(SummaryDetail.self, from: data)
        let text = (detail.summary_markdown ?? detail.summary_text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ApiError.http(200, "No summary") }
        return text
    }

    private struct SummaryDetail: Decodable {
        let summary_text: String?
        let summary_markdown: String?
    }

    /// A note's transcript as plain text — one "Speaker: text" line per
    /// segment. Speaker labels: the diarization label when Granola has one
    /// ("Speaker A"), else microphone → "Me", speaker/system → "Them".
    /// Returns nil when the note has no transcript or the Get 404s.
    func fetchTranscript(noteId: String) async throws -> String? {
        var comps = URLComponents(
            url: Self.base.appendingPathComponent("notes/\(noteId)"),
            resolvingAgainstBaseURL: false,
        )!
        comps.queryItems = [URLQueryItem(name: "include", value: "transcript")]
        let data: Data
        do { data = try await get(comps.url!) }
        catch ApiError.notFound { return nil }

        // Tolerant decode: transcript alongside the note fields, or the
        // whole thing wrapped in { note: … }.
        var segments = (try? JSONDecoder().decode(NoteDetail.self, from: data))?.transcript
        if segments == nil {
            segments = (try? JSONDecoder().decode(WrappedNoteDetail.self, from: data))?.note?.transcript
        }
        guard let segments, !segments.isEmpty else { return nil }

        let lines = segments.compactMap { seg -> String? in
            let text = (seg.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(Self.speakerLabel(seg.speaker)): \(text)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func speakerLabel(_ s: WireSpeaker?) -> String {
        if let label = s?.diarization_label?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
            return label
        }
        switch s?.source?.lowercased() {
        case "microphone": return "Me"
        case "speaker", "system": return "Them"
        default: return "Speaker"
        }
    }

    // MARK: - Transport (rate-limit aware)

    /// One GET with auth. Always sleeps the politeness delay after the
    /// request so sequential callers stay under Granola's sustained limit;
    /// a 429 gets exactly one retry after 2 seconds.
    private func get(_ url: URL) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            try await Task.sleep(nanoseconds: Self.interRequestDelayNs)
            switch status {
            case 200: return data
            case 401, 403: throw ApiError.badKey
            case 404: throw ApiError.notFound
            case 429 where attempt == 1:
                try await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            default:
                throw ApiError.http(status, String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    // MARK: - Wire structs

    private struct NotesPage: Decodable {
        let notes: [WireNote]
        let hasMore: Bool?
        let cursor: String?
    }

    private struct WireNote: Decodable {
        let id: String
        let title: String?
        let owner: WireOwner?
        let summary: String?
        let created_at: String?

        func toNote() -> Note {
            Note(
                noteId: id,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? title!.trimmingCharacters(in: .whitespacesAndNewlines)
                    : "Untitled Meeting",
                ownerName: owner?.name,
                ownerEmail: owner?.email,
                summary: summary,
                createdAt: Self.iso(created_at),
            )
        }

        private static func iso(_ s: String?) -> Date? {
            guard let s, !s.isEmpty else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
    }

    private struct WireOwner: Decodable {
        let name: String?
        let email: String?
    }

    private struct NoteDetail: Decodable {
        let transcript: [WireSegment]?
    }
    private struct WrappedNoteDetail: Decodable {
        let note: NoteDetail?
    }
    private struct WireSegment: Decodable {
        let speaker: WireSpeaker?
        let text: String?
    }
    private struct WireSpeaker: Decodable {
        let source: String?
        let diarization_label: String?
    }
}
