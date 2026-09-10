import SwiftUI

struct WorkspaceGranola: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @State private var key = ""
    @State private var connected = false
    @State private var editingKey = false
    @State private var notes: [GranolaApiClient.Note] = []
    @State private var selection = GranolaNoteSelection()
    @State private var folders: [GranolaApiClient.Folder] = []
    @State private var folderID = "all"
    @State private var foldersLoaded = false
    @State private var operation: Task<Void, Never>?
    @State private var busy = false
    @State private var message: String?
    @State private var loaded = false
    @State private var suggesting = false
    @State private var suggestion: WorkspaceSourceSuggestion?
    @State private var suggestedNotes: [GranolaApiClient.Note] = []

    var body: some View {
        WorkspacePanel {
            HStack {
                Label("Granola", systemImage: "waveform").font(.custom("AvenirNext-DemiBold", size: 18))
                Spacer()
                Text(connected ? "Key saved on this Mac" : "Optional connection").font(.caption).foregroundStyle(.secondary)
            }
            Text("Download selected notes from Granola. Your workspace and model answers stay on this Mac. New notes are private; importing again preserves their existing sharing permissions.").foregroundStyle(.secondary)
            if !connected || editingKey {
                SecureField("Granola API key", text: $key).textFieldStyle(.roundedBorder).accessibilityIdentifier("granola-api-key")
                HStack {
                    Button(connected ? "Save API key" : "Connect Granola") { operation = Task { await load(saveKey: true) } }
                        .buttonStyle(.borderedProminent).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    if connected { Button("Cancel key change") { editingKey = false; key = "" } .disabled(busy) }
                    Link("Get an API key", destination: URL(string: "https://docs.granola.ai/introduction")!)
                }
                Text("Create a key in Granola → Settings → Connectors → API keys. API access requires an eligible Granola plan and your workspace’s permission.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Browse notes") { operation = Task { await load(saveKey: false) } }.disabled(busy)
                    Button("Change API key") { editingKey = true; key = ""; message = nil }.disabled(busy)
                    Button("Disconnect") {
                        Keychain.deleteServiceToken(service: "granola_api")
                        connected = false; editingKey = false; key = ""; notes = []; selection.clear(); loaded = false; folders = []; foldersLoaded = false; folderID = "all"
                        message = "Disconnected. Previously imported notes remain on this Mac."
                    }.disabled(busy)
                }
            }
            if busy {
                HStack {
                    ProgressView(suggesting ? "Preparing a starting set with your local model…" : "Loading from Granola…").controlSize(.small)
                    Spacer()
                    Button("Cancel") { operation?.cancel() }
                }
            }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            if foldersLoaded {
                Picker("Folder", selection: Binding(get: { folderID }, set: { value in
                    folderID = value; notes = []; loaded = false; suggestion = nil; suggestedNotes = []
                    operation = Task { await loadNotes() }
                })) {
                    Text("All notes").tag("all")
                    ForEach(folders) { folder in Text(folder.path(in: folders)).tag(folder.id) }
                }.accessibilityIdentifier("granola-folder").disabled(busy)
                Text("Folder views include subfolders. Selections stay checked when you switch folders.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loaded && notes.isEmpty {
                Text(folderID == "all" ? "No notes available through this key." : "No accessible notes in this folder or its subfolders.").foregroundStyle(.secondary)
            }
            if !notes.isEmpty, let purpose = store.data.purpose {
                HStack {
                    Button("Suggest a starting set") { operation = Task { await suggest(for: purpose) } }
                        .disabled(busy || store.working)
                    Text("For: " + purpose.title).font(.caption).foregroundStyle(.secondary)
                }
                Text("Reads summary excerpts from the first \(min(notes.count, 30)) notes in this view. Your local model explains useful starting material; nothing is imported until you choose.")
                    .font(.caption).foregroundStyle(.secondary)
                if let suggestion {
                    Text("Local suggestion · review before importing").font(.headline)
                    Text(suggestion.explanation).textSelection(.enabled)
                    ForEach(suggestedNotes) { Text($0.title).font(.callout.weight(.medium)) }
                    if !suggestedNotes.isEmpty {
                        Button("Select suggested notes (\(suggestedNotes.count))") {
                            selection.clear(); selection.select(suggestedNotes)
                        }.disabled(busy)
                    }
                }
            }
            if !notes.isEmpty {
                HStack {
                    Text("\(selection.count(in: notes)) of \(notes.count) selected here").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if quickSelectCount > 0 {
                        Button(availableSlots == 30 ? "Select \(quickSelectCount)" : "Select remaining \(quickSelectCount)") {
                            selection.selectFirstNew(notes, limit: quickSelectCount, importedIDs: importedNoteIDs)
                        }.disabled(busy).accessibilityIdentifier("granola-select-capacity")
                            .help("Replace the current selection across all folders with the first \(quickSelectCount) new notes in this view.")
                    }
                    Button("Select all") { selection.select(notes) }.disabled(busy || selection.count(in: notes) == notes.count)
                        .accessibilityIdentifier("granola-select-all")
                    Button("Clear selection") { selection.deselect(notes) }.disabled(busy || selection.count(in: notes) == 0)
                        .accessibilityIdentifier("granola-clear-folder")
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(notes) { note in
                            Toggle(isOn: Binding(get: { selection.contains(note.id) }, set: { selection.set(note, selected: $0) })) {
                                VStack(alignment: .leading) {
                                    Text(note.title)
                                    if let date = note.createdAt { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }.padding(4)
                }.frame(maxHeight: 280).disabled(busy)
            }
            if loaded || !selection.notes.isEmpty {
                HStack {
                    Button("Import selected notes (\(selection.notes.count))") { operation = Task { await download() } }
                        .buttonStyle(.borderedProminent).disabled(selection.notes.isEmpty || busy || exceedsCapacity)
                    if !selection.notes.isEmpty { Button("Clear all folders") { selection.clear() }.disabled(busy) }
                }
                Text(exceedsCapacity
                     ? "\(newNoteCount) new notes selected; room for \(availableSlots). Select fewer notes or remove sources before importing."
                     : "\(newNoteCount) new notes selected · \(availableSlots) source slots available. Notes already imported will be updated.")
                    .font(.caption).foregroundStyle(exceedsCapacity ? Color.red : .secondary)
                Text("Imports summaries only. Transcripts and private scratch notes are excluded. Updates are manual.").font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { connected = Keychain.hasServiceToken(service: "granola_api") }
            .onDisappear { operation?.cancel() }
            .onChange(of: store.data.purpose) { _ in suggestion = nil; suggestedNotes = [] }
    }

    private var availableSlots: Int { max(0, 30 - store.data.documents.count) }
    private var importedNoteIDs: Set<String> {
        Set(store.data.documents.compactMap(\.externalID).filter { $0.hasPrefix("granola:") }.map { String($0.dropFirst("granola:".count)) })
    }
    private var quickSelectCount: Int { min(availableSlots, Set(notes.map(\.id)).subtracting(importedNoteIDs).count) }
    private var newNoteCount: Int {
        let imported = Set(store.data.documents.compactMap(\.externalID))
        return selection.notes.filter { !imported.contains("granola:" + $0.id) }.count
    }
    private var exceedsCapacity: Bool { newNoteCount > availableSlots }

    @MainActor private func suggest(for purpose: WorkspacePurpose) async {
        busy = true; suggesting = true; message = nil; suggestion = nil; suggestedNotes = []
        defer { busy = false; suggesting = false }
        guard let token = await Task.detached(operation: { Keychain.loadServiceToken(service: "granola_api") }).value else { connected = false; return }
        do {
            let candidates = Array(notes.prefix(30))
            var documents: [WorkspaceDocument] = []
            var noteIDs: [UUID: String] = [:]
            let client = GranolaApiClient(apiKey: token)
            for note in candidates {
                try Task.checkCancellation()
                let summary = try await client.fetchSummary(noteId: note.id)
                let document = WorkspaceDocument(title: note.title, text: String(summary.prefix(6000)), origin: "Granola preview excerpt")
                documents.append(document); noteIDs[document.id] = note.id
            }
            let result = await store.suggestSources(documents, for: purpose)
            try Task.checkCancellation()
            guard store.data.purpose == purpose else { message = "Your purpose changed. Ask for a new suggestion."; return }
            suggestion = result
            let ids = Set((result?.sources ?? []).compactMap { noteIDs[$0.id] })
            suggestedNotes = candidates.filter { ids.contains($0.id) }
        } catch is CancellationError { message = "Suggestions canceled. Nothing was imported." }
        catch { showConnectionError(error) }
    }

    @MainActor private func loadNotes() async {
        busy = true; message = nil
        defer { busy = false }
        guard let token = await Task.detached(operation: { Keychain.loadServiceToken(service: "granola_api") }).value else { connected = false; return }
        do {
            let result = try await GranolaApiClient(apiKey: token).listNotes(createdAfter: nil, folderID: folderID == "all" ? nil : folderID, limit: nil)
            try Task.checkCancellation()
            notes = result; loaded = true
        } catch is CancellationError { message = "Loading canceled. Your selections are saved." }
        catch { showConnectionError(error) }

    }

    @MainActor private func load(saveKey: Bool) async {
        busy = true; message = nil; suggestion = nil; suggestedNotes = []
        defer { busy = false }
        let token: String
        if saveKey { token = key.trimmingCharacters(in: .whitespacesAndNewlines) }
        else { token = await Task.detached { Keychain.loadServiceToken(service: "granola_api") ?? "" }.value }
        do {
            let client = GranolaApiClient(apiKey: token)
            let availableFolders: [GranolaApiClient.Folder]
            do { availableFolders = try await client.listFolders() }
            catch is CancellationError { throw CancellationError() }
            catch { availableFolders = []; message = "Folders could not be loaded. You can still browse all notes. Try Browse notes again to retry." }
            let target = availableFolders.contains(where: { $0.id == folderID }) ? folderID : "all"
            let result = try await client.listNotes(createdAfter: nil, folderID: target == "all" ? nil : target, limit: nil)
            try Task.checkCancellation()
            if saveKey {
                Keychain.saveServiceToken(service: "granola_api", token: token)
                guard Keychain.loadServiceToken(service: "granola_api") == token else { throw WorkspaceStorageError.invalid("The key could not be saved to Keychain. Please try again.") }
            }
            if saveKey { selection.clear() }
            connected = true; editingKey = false; key = ""; notes = result; folders = availableFolders; foldersLoaded = true; loaded = true
            if folderID != target { folderID = target }
        } catch is CancellationError { message = "Loading canceled. Your selections are saved." }
        catch { showConnectionError(error) }
    }

    @MainActor private func showConnectionError(_ error: Error) {
        if case GranolaApiClient.ApiError.badKey = error {
            editingKey = true
            key = ""
            message = "Granola rejected this key or its access. Paste a replacement in the API key field above, then save it."
        } else { message = error.localizedDescription }
    }

    @MainActor private func download() async {
        busy = true; message = nil
        defer { busy = false }
        guard let token = await Task.detached(operation: { Keychain.loadServiceToken(service: "granola_api") }).value else { connected = false; return }
        do {
            let client = GranolaApiClient(apiKey: token)
            var downloaded: [(id: String, title: String, text: String)] = []
            for note in selection.notes {
                downloaded.append((note.id, note.title, try await client.fetchSummary(noteId: note.id)))
            }
            try Task.checkCancellation()
            if store.importGranolaNotes(downloaded) {
                message = "Saved \(downloaded.count) notes on this Mac."; selection.clear()
            }
        } catch { showConnectionError(error) }
    }
}

/// Shared selection across folder views. A note belongs to the selection once,
/// even when Granola returns it in several folders or in a parent folder.
struct GranolaNoteSelection {
    private var selected: [String: GranolaApiClient.Note] = [:]
    var notes: [GranolaApiClient.Note] { selected.values.sorted { $0.id < $1.id } }
    func contains(_ id: String) -> Bool { selected[id] != nil }
    func count(in notes: [GranolaApiClient.Note]) -> Int { Set(notes.map(\.id)).filter { contains($0) }.count }
    mutating func set(_ note: GranolaApiClient.Note, selected isSelected: Bool) {
        if isSelected { selected[note.id] = note } else { selected.removeValue(forKey: note.id) }
    }
    mutating func select(_ notes: [GranolaApiClient.Note]) { for note in notes { set(note, selected: true) } }
    mutating func deselect(_ notes: [GranolaApiClient.Note]) { for note in notes { set(note, selected: false) } }
    mutating func selectFirstNew(_ notes: [GranolaApiClient.Note], limit: Int, importedIDs: Set<String>) {
        clear()
        guard limit > 0 else { return }
        for note in notes where !importedIDs.contains(note.id) {
            set(note, selected: true)
            if selected.count == limit { break }
        }
    }
    mutating func clear() { selected.removeAll() }
}
