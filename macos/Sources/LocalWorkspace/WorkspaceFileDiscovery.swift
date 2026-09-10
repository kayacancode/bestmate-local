import SwiftUI
import PDFKit

struct WorkspaceFileMatch: Identifiable {
    let document: WorkspaceDocument
    let relativePath: String
    let excerpt: String
    let matchedTerms: [String]
    let score: Int
    var id: UUID { document.id }
}

struct WorkspaceFileSearchResult {
    var matches: [WorkspaceFileMatch] = []
    var scanned = 0
    var skipped = 0
    var limited = false
}

/// A bounded, local text search. No persistent index or external process is needed.
enum WorkspaceFileSearch {
    static let extensions: Set<String> = ["txt", "md", "markdown", "pdf", "swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "java", "rb"]
    static let excludedDirectories: Set<String> = ["node_modules", "vendor", "build", "dist", "target", "DerivedData"]

    static func terms(_ query: String) -> [String] {
        var seen = Set<String>()
        return query.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(12).map { $0 }
    }

    static func search(folder: URL, query: String) throws -> WorkspaceFileSearchResult {
        let terms = terms(query)
        guard !terms.isEmpty else { throw WorkspaceStorageError.invalid("Enter a few words or phrases, separated by commas.") }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw WorkspaceStorageError.invalid("This folder could not be searched. Choose it again.")
        }
        var result = WorkspaceFileSearchResult()
        var bytesRead = 0
        var visited = 0
        for case let file as URL in entries {
            try Task.checkCancellation()
            visited += 1
            if visited > 5000 || result.scanned >= 2000 || bytesRead >= 32 * 1024 * 1024 { result.limited = true; break }
            guard let values = try? file.resourceValues(forKeys: keys) else { result.skipped += 1; continue }
            if values.isSymbolicLink == true { entries.skipDescendants(); result.skipped += 1; continue }
            if values.isDirectory == true {
                if excludedDirectories.contains(file.lastPathComponent) { entries.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, extensions.contains(file.pathExtension.lowercased()) else { continue }
            let resolved = file.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path == "/" ? "/" : root.path + "/"),
                  let size = values.fileSize, size <= 2 * 1024 * 1024 else { result.skipped += 1; continue }
            result.scanned += 1
            bytesRead += size
            let content: String
            if file.pathExtension.lowercased() == "pdf" {
                guard let text = PDFDocument(url: resolved)?.string else { result.skipped += 1; continue }
                content = text
            } else {
                guard let text = try? String(contentsOf: resolved, encoding: .utf8) else { result.skipped += 1; continue }
                content = text
            }
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 50_000 else { result.skipped += 1; continue }
            let relative = String(resolved.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let matched = terms.filter { relative.localizedCaseInsensitiveContains($0) || text.localizedCaseInsensitiveContains($0) }
            guard !matched.isEmpty else { continue }
            let score = matched.reduce(0) { $0 + (relative.localizedCaseInsensitiveContains($1) ? 3 : 1) }
            let firstRange = matched.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.min { $0.lowerBound < $1.lowerBound }
            let start = firstRange.map { text.index($0.lowerBound, offsetBy: -100, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
            let end = text.index(start, offsetBy: 650, limitedBy: text.endIndex) ?? text.endIndex
            let excerpt = (start == text.startIndex ? "" : "…") + String(text[start..<end]) + (end == text.endIndex ? "" : "…")
            var document = WorkspaceDocument(title: file.deletingPathExtension().lastPathComponent, text: text, origin: relative)
            document.externalID = "local-file:" + resolved.path
            result.matches.append(WorkspaceFileMatch(document: document, relativePath: relative, excerpt: excerpt, matchedTerms: matched, score: score))
            // Keep only the best 100 results in memory, while continuing to search.
            if result.matches.count > 100 {
                result.matches.sort { $0.score == $1.score ? $0.relativePath < $1.relativePath : $0.score > $1.score }
                result.matches.removeLast(); result.limited = true
            }
        }
        result.matches.sort { $0.score == $1.score ? $0.relativePath < $1.relativePath : $0.score > $1.score }
        return result
    }
}

struct WorkspaceFileDiscovery: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @Environment(\.dismiss) var dismiss
    @State private var query = "decision, because, tradeoff"
    @State private var folder: URL?
    @State private var result: WorkspaceFileSearchResult?
    @State private var selected = Set<UUID>()
    @State private var busy = false
    @State private var message: String?
    @State private var suggestion: WorkspaceSourceSuggestion?
    @State private var task: Task<Void, Never>?

    private var chosen: [WorkspaceDocument] { (result?.matches ?? []).filter { selected.contains($0.id) }.map(\.document) }
    private var newCount: Int {
        let existing = Set(store.data.documents.compactMap(\.externalID))
        return chosen.filter { !existing.contains($0.externalID ?? "") }.count
    }
    private var fits: Bool {
        let replacing = Set(chosen.compactMap(\.externalID))
        let kept = store.data.documents.filter { !replacing.contains($0.externalID ?? "") }
        return kept.count + chosen.count <= 30 && kept.reduce(0, { $0 + $1.text.count }) + chosen.reduce(0, { $0 + $1.text.count }) <= 200_000
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Find useful material").font(.headline); Spacer(); Button("Done") { task?.cancel(); dismiss() } }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    WorkspaceHeading(eyebrow: store.data.purpose?.title ?? "Search your files", title: "Find the decisions behind your work.", detail: "Choose a folder to search on this Mac. Preview the matches and choose what to import.")
                    WorkspacePanel {
                        HStack {
                            Button(folder == nil ? "Choose folder…" : "Change folder…") { chooseFolder() }.disabled(busy)
                            if let folder { Text(folder.lastPathComponent).font(.headline) }
                        }
                        TextField("Words or phrases, separated by commas", text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("discovery-query").disabled(busy)
                        HStack {
                            Button("Search folder") { startSearch() }.buttonStyle(.borderedProminent).disabled(folder == nil || WorkspaceFileSearch.terms(query).isEmpty || busy)
                            if let purpose = store.data.purpose { Button("Use purpose terms") { query = purpose.searchTerms.joined(separator: ", ") }.disabled(busy) }
                            if busy { ProgressView().controlSize(.small); Button("Cancel") { task?.cancel() } }
                        }
                        Text("Searches text, Markdown, text-bearing PDFs, and common code files. Hidden files, symbolic links, and build/dependency folders are skipped. Large or unreadable files are skipped; no files are uploaded.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let message { Text(message).foregroundStyle(.secondary) }
                    if let result {
                        HStack {
                            Text("\(result.matches.count) matches · \(result.scanned) files searched · \(result.skipped) skipped").font(.caption)
                            Spacer()
                            Button("Select what fits") { selectWhatFits(result.matches) }.disabled(busy)
                            Button("Clear selection") { selected = [] }.disabled(busy)
                        }
                        if result.limited { Text("Showing up to 100 best matches from a bounded search. Choose a smaller folder or more specific terms to narrow the results.").font(.caption).foregroundStyle(.secondary) }
                        if result.matches.isEmpty { Text("No matching text found. Try another term or a different folder.").foregroundStyle(.secondary) }
                        if let purpose = store.data.purpose, !result.matches.isEmpty {
                            Button("Ask my local model for a starting set") {
                                busy = true
                                task = Task {
                                    defer { busy = false }
                                    let candidates = Array(result.matches.prefix(30)).map { match -> WorkspaceDocument in
                                        var document = match.document
                                        document.text = match.excerpt
                                        return document
                                    }
                                    suggestion = await store.suggestSources(candidates, for: purpose)
                                }
                            }.disabled(busy || store.working)
                            Text("The model reviews excerpts from the first 30 matches. Search matches are based on words; model suggestions use the cited content.").font(.caption).foregroundStyle(.secondary)
                        }
                        if let suggestion {
                            WorkspacePanel {
                                Text("Local-model suggestion").font(.headline)
                                Text(suggestion.explanation).textSelection(.enabled)
                                ForEach(suggestion.sources) { Text($0.title).font(.callout.weight(.medium)) }
                                if !suggestion.sources.isEmpty {
                                    Button("Select suggested files") { selected = Set(suggestion.sources.map(\.id)) }.disabled(busy)
                                }
                            }
                        }
                        ForEach(result.matches) { match in
                            WorkspacePanel {
                                Toggle(isOn: Binding(get: { selected.contains(match.id) }, set: { if $0 { selected.insert(match.id) } else { selected.remove(match.id) } })) {
                                    Text(match.document.title).font(.headline)
                                }.disabled(busy)
                                Text(match.relativePath).font(.caption).foregroundStyle(.secondary)
                                Text("Matches: " + match.matchedTerms.joined(separator: ", ")).font(.caption).foregroundStyle(WorkspaceTheme.accent)
                                Text(match.excerpt).font(.callout).textSelection(.enabled)
                                DisclosureGroup("Read full source") { Text(match.document.text).font(.callout).textSelection(.enabled) }
                            }
                        }
                    }
                }.padding(28)
            }
            Divider()
            HStack {
                Text(fits ? "\(chosen.count) selected · \(newCount) new sources" : "This selection exceeds 30 sources or 200,000 characters. Select fewer files.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Import selected files") {
                    if store.importDiscoveredSources(chosen) { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(chosen.isEmpty || !fits || busy)
            }.padding(20)
        }.frame(width: 880, height: 700).background(WorkspaceTheme.background)
            .task { query = (store.data.purpose?.searchTerms ?? ["decision", "because", "tradeoff"]).joined(separator: ", ") }
            .onDisappear { task?.cancel() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Search this folder"
        if panel.runModal() == .OK, let url = panel.url { folder = url; result = nil; selected = []; suggestion = nil; message = nil; startSearch() }
    }

    private func startSearch() {
        guard let folder else { return }
        let query = query
        busy = true; message = nil; suggestion = nil; selected = []; result = nil
        task = Task {
            defer { busy = false }
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            let worker = Task.detached { try WorkspaceFileSearch.search(folder: folder, query: query) }
            do {
                let found = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                result = found
                message = "Results are local snapshots. Search again to refresh changed files; importing copies only your selection."
            } catch is CancellationError { message = "Search canceled. Nothing was imported." }
            catch { message = error.localizedDescription }
        }
    }

    private func selectWhatFits(_ matches: [WorkspaceFileMatch]) {
        selected = []
        for match in matches {
            selected.insert(match.id)
            if !fits { selected.remove(match.id) }
        }
    }
}
