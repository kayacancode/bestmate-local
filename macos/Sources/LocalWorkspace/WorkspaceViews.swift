import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceTheme {
    static let rail = Color(red: 0.14, green: 0.20, blue: 0.16)
    static let background = Color(red: 0.91, green: 0.93, blue: 0.90)
    static let paper = Color(red: 0.988, green: 0.992, blue: 0.976)
    static let ink = Color(red: 0.125, green: 0.16, blue: 0.14)
    static let accent = Color(red: 0.19, green: 0.36, blue: 0.24)
    static let line = Color(red: 0.84, green: 0.86, blue: 0.83)
}

enum WorkspacePage: String, CaseIterable, Identifiable {
    case workspace = "Workspace", knowledge = "Knowledge", review = "Review", team = "Team", skills = "Skills", history = "History", settings = "Local setup"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .workspace: return "rectangle.3.group"
        case .knowledge: return "doc.on.doc"
        case .review: return "rectangle.stack"
        case .team: return "person.2"
        case .skills: return "slider.horizontal.3"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "externaldrive.connected.to.line.below"
        }
    }
}

struct NativeWorkspaceRoot: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @State private var page: WorkspacePage = .workspace
    @State private var showingOnboarding = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("bestmate").font(.custom("AvenirNext-DemiBold", size: 27)).tracking(-1)
                    Label("On this Mac", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.top, 18)
                VStack(spacing: 6) {
                    ForEach(WorkspacePage.allCases) { item in
                        Button { page = item } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.icon).frame(width: 20)
                                Text(item.rawValue)
                                Spacer()
                                if item == .review {
                                    let count = store.data.judgments.filter { $0.status == .draft }.count
                                    if count > 0 { Text("\(count)").font(.caption).padding(.horizontal, 6).background(.white.opacity(0.15), in: Capsule()) }
                                }
                            }.padding(.horizontal, 14).frame(height: 44)
                                .background(page == item ? Color.white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("nav-" + item.rawValue)
                            .accessibilityAddTraits(page == item ? .isSelected : [])
                    }
                }.padding(.horizontal, 12)
                Spacer()
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.data.name).font(.headline)
                    Text("Sources: \(store.data.documents.count) · Approved: \(store.data.judgments.filter { $0.status == .approved }.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }.frame(width: 220).frame(maxHeight: .infinity).foregroundStyle(Color.white.opacity(0.92)).background(WorkspaceTheme.rail)
            VStack(spacing: 0) {
                if let notice = store.notice {
                    HStack { Text(notice).font(.callout); Spacer(); Button("Dismiss") { store.notice = nil } }
                        .padding(12).background(WorkspaceTheme.accent.opacity(0.08))
                }
                Group {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            switch page {
                            case .workspace:
                                if !store.data.onboardingComplete {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Finish setting up your workspace").font(.headline)
                                            Text("Your progress is saved. Continue when you’re ready.").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Continue setup") { showingOnboarding = true }.buttonStyle(.borderedProminent)
                                    }.padding(18).background(WorkspaceTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                                }
                                WorkspaceHome()
                            case .knowledge: WorkspaceKnowledge()
                            case .review: WorkspaceReview()
                            case .team: WorkspaceTeam()
                            case .skills: WorkspaceSkills()
                            case .history: WorkspaceHistory()
                            case .settings: WorkspaceSetup()
                            }
                        }.padding(36).frame(maxWidth: 1040, alignment: .leading).frame(maxWidth: .infinity)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(WorkspaceTheme.background)
        }
        .font(.custom("AvenirNext-Regular", size: 14))
        .foregroundStyle(WorkspaceTheme.ink)
        .tint(WorkspaceTheme.accent)
        .preferredColorScheme(.light)
        .disclosureGroupStyle(WorkspaceDisclosureStyle())
        .sheet(isPresented: $showingOnboarding) {
            VStack(spacing: 0) {
                HStack {
                    Text("Workspace setup").font(.headline)
                    Spacer()
                    Button("Save & close") { showingOnboarding = false }
                }.padding(20)
                Divider()
                WorkspaceOnboarding()
            }.frame(minWidth: 900, minHeight: 620)
                .background(WorkspaceTheme.background)
                .onChange(of: store.data.onboardingComplete) { complete in
                    if complete { showingOnboarding = false }
                }
        }
        .alert("Something needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .overlay(alignment: .bottomTrailing) {
            if store.working { HStack { ProgressView().controlSize(.small); Text("Working…").font(.callout) }.padding().background(.regularMaterial, in: Capsule()).padding() }
        }
    }
}

struct WorkspaceDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}

struct WorkspaceHeading: View {
    let eyebrow: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(.secondary)
            Text(title).font(.custom("AvenirNext-Medium", size: 40)).tracking(-1)
            Text(detail).font(.custom("AvenirNext-Regular", size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct WorkspacePanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceTheme.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkspaceTheme.line))
    }
}

struct WorkspaceHome: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @State private var goal = ""
    var body: some View {
        WorkspaceHeading(eyebrow: "Your working context", title: "What needs your judgment?", detail: "Ask against your material, review the evidence, and decide what a teammate can rely on.")
        WorkspacePanel {
            Text("Working on").font(.headline)
            HStack {
                TextField("Name this workspace or project", text: $goal)
                Button("Save") { store.update { $0.name = goal.trimmingCharacters(in: .whitespacesAndNewlines) }; store.notice = "Workspace updated." }.disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.onAppear { goal = store.data.name }
        }
        HStack(alignment: .top, spacing: 20) {
            WorkspaceQuestionBox().frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 20) {
        let changed = store.data.judgments.filter { $0.status == .approved && !store.evidenceIsCurrent($0) }
        if !changed.isEmpty {
            WorkspacePanel {
                Label("Evidence has changed", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                Text("These decisions are excluded from future answers until you review a revision.").foregroundStyle(.secondary)
                ForEach(changed) { judgment in
                    HStack { Text(judgment.question); Spacer(); Button("Review revision") { store.revision(judgment); store.notice = "Revision added to Review." } }
                }
            }
        }
        WorkspacePanel {
            Text("Latest decisions").font(.headline)
            if store.data.judgments.isEmpty { Text("Your first reviewed decision will appear here.").foregroundStyle(.secondary) }
            ForEach(Array(store.data.judgments.suffix(4).reversed())) { item in
                VStack(alignment: .leading, spacing: 5) { Text(item.question).font(.headline); Text(item.status.rawValue.capitalized + " · " + item.topic).font(.caption).foregroundStyle(.secondary) }
            }
        }
            }.frame(width: 280)
        }
    }
}

struct WorkspaceQuestionBox: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    var memberID: UUID? = nil
    var twinID: UUID? = nil
    var initialTopic = "Engineering"
    @State private var conversationID = UUID().uuidString
    @State private var topic = ""
    @State private var question = ""
    @State private var result: WorkspaceConsultation?
    private var sharedSubjects: [String] {
        WorkspaceAccessPolicy.sharedSubjects(member: store.data.members.first { $0.id == memberID }, twin: store.data.twins.first { $0.id == twinID })
    }
    private var sharedQuestion: Bool { memberID != nil || twinID != nil }
    private var selectedSubject: String { sharedQuestion ? (sharedSubjects.contains(topic) ? topic : sharedSubjects.first ?? "") : topic }
    var body: some View {
        WorkspacePanel {
            Text(memberID == nil ? "Ask your knowledge" : "Try this person’s access").font(.headline)
            if store.data.runtime.backend == "granite-switch" {
                HStack {
                    Text("Follow-up questions use this conversation’s recent turns.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("New conversation") { conversationID = UUID().uuidString; result = nil; question = "" }.disabled(store.working)
                }
            }
            if sharedQuestion {
                if !(store.data.members.first { $0.id == memberID }?.topics.isEmpty == true && store.data.twins.first { $0.id == twinID }?.topics.isEmpty == true) {
                Picker("Allowed subject", selection: Binding(get: { selectedSubject }, set: { topic = $0 })) {
                    if sharedSubjects.isEmpty { Text("No shared subjects").tag("") }
                    ForEach(sharedSubjects, id: \.self) { Text($0).tag($0) }
                }.accessibilityIdentifier("question-topic").disabled(sharedSubjects.isEmpty || store.working)
                }
                if sharedSubjects.isEmpty {
                    Text("This person and twin have no shared allowed subject. In Team, edit the person under People & access and the twin under Twins so they share a subject.").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                TextField("Subject", text: $topic).textFieldStyle(.roundedBorder).accessibilityIdentifier("question-topic")
            }
            TextField("What would you like to decide?", text: $question, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder).accessibilityIdentifier("question-text")
            HStack {
                Button(store.working ? "Thinking…" : "Ask locally") { ask(false) }.buttonStyle(.borderedProminent)
                if memberID == nil { Button("Create a review card") { ask(true) } }
            }.disabled(store.working || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (sharedQuestion && selectedSubject.isEmpty))
            if let started = store.questionStartedAt {
                VStack(alignment: .leading, spacing: 10) {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Working · \(Int(max(0, context.date.timeIntervalSince(started))))s elapsed").font(.callout.weight(.medium))
                        }
                    }
                    if store.questionProgress.isEmpty {
                        Text(store.progressUnavailable ? "Live steps are unavailable. The request is still waiting for the local runtime." : "Connecting to the local runtime…").font(.callout).foregroundStyle(.secondary)
                    }
                    if let current = store.questionProgress.last { Text(current.title).font(.callout.weight(.medium)) }
                    if !store.questionProgress.isEmpty {
                    DisclosureGroup("View runtime steps (\(store.questionProgress.count))") {
                    ForEach(Array(store.questionProgress.enumerated()), id: \.offset) { index, event in
                        HStack(alignment: .top) {
                            Image(systemName: index == store.questionProgress.count - 1 ? "circle.inset.filled" : "circle.fill").font(.caption2)
                            Text(event.title)
                            Spacer()
                            Text("at \(Int(event.seconds))s").monospacedDigit()
                        }.font(.caption).foregroundStyle(index == store.questionProgress.count - 1 ? .primary : .secondary)
                    }
                    }
                    }
                    if store.progressUnavailable && !store.questionProgress.isEmpty {
                        Text("Live updates interrupted. Showing the last reported step.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Steps are reported by the local runtime. Some take longer than others; requests stop after four minutes.").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 8).accessibilityIdentifier("question-progress")
            }
            if let result {
                Divider()
                Text(result.outcome.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(result.answer).textSelection(.enabled)
                Text(String(format: "%.1f seconds", result.seconds)).font(.caption).foregroundStyle(.secondary)
                if !result.sourceIDs.isEmpty {
                    DisclosureGroup("Material retrieved") {
                        ForEach(store.data.documents.filter { result.sourceIDs.contains($0.id) }) { doc in
                            VStack(alignment: .leading) { Text(doc.title).font(.headline); Text(doc.text).font(.callout).textSelection(.enabled) }.padding(.vertical, 6)
                        }
                    }
                }
                Text("Model checks can miss errors. An answer is not your approval, and citations still need review.").font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear {
            topic = memberID == nil ? (store.data.purpose?.topic ?? initialTopic) : initialTopic
            if memberID == nil, question.isEmpty, let purpose = store.data.purpose { question = purpose.question }
        }
    }
    func ask(_ review: Bool) {
        let subject = selectedSubject
        guard !sharedQuestion || sharedSubjects.contains(subject) else { return }
        Task { result = await store.consult(question: question, topic: subject, memberID: memberID, twinID: twinID, makeReview: review, conversationID: conversationID) }
    }
}

struct WorkspaceSetup: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    var onboarding = false
    var body: some View {
        WorkspaceHeading(eyebrow: "Environment", title: "Choose where answers run.", detail: "Knowledge and retrieval stay on this Mac. Use a local model or send selected excerpts to your approved model endpoint.")
        WorkspaceRuntimeSettings(controller: store.runtime)
        if !onboarding { WorkspacePanel {
            Text("Workspace storage").font(.headline)
            Text(store.repository.fileURL.path).font(.caption.monospaced()).textSelection(.enabled)
            Text("Sources, decisions and team settings are saved locally. Existing legacy account data is preserved separately.").foregroundStyle(.secondary)
            Button("Revisit onboarding") { store.update { $0.onboardingComplete = false; $0.onboardingStep = 0 }; store.notice = "Open Workspace to walk through setup again." }
        } }
    }
}

struct WorkspaceRuntimeSettings: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @ObservedObject var controller: WorkspaceRuntimeController
    @State private var configuration = WorkspaceRuntimeConfiguration()
    @State private var modelKey = ""
    var body: some View {
        WorkspacePanel {
            Text("Local model").font(.headline)
            Picker("Answer pipeline", selection: $configuration.backend) {
                Text("Your model endpoint · OpenAI compatible").tag("openai-compatible")
                Text("Granite + Hugging Face RAG adapters").tag("granite-hf-adapters")
                Text("Granite Switch · notebook adapter flow").tag("granite-switch")
                Text("Ollama baseline · Llama 3.1").tag("ollama-baseline")
            }
            if configuration.backend == "openai-compatible" {
                Text("Local keyword retrieval requires no model downloads. Your question and selected source excerpts are sent to the endpoint below. This uses standard model calls, not Granite adapters.").font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model base URL · required")
                    TextField("https://models.your-organization.example/v1", text: Binding(get: { configuration.modelURL ?? "" }, set: { configuration.modelURL = $0 })).textFieldStyle(.roundedBorder)
                    Text("Model name · required")
                    TextField("Model identifier from your server", text: Binding(get: { configuration.modelName ?? "" }, set: { configuration.modelName = $0 })).textFieldStyle(.roundedBorder)
                    Text("API key · optional")
                    SecureField("Leave empty if your endpoint needs no key", text: $modelKey).textFieldStyle(.roundedBorder)
                    Text("The key is saved in macOS Keychain when you check the connection. The test sends a short prompt, without your documents.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Granite uses query refinement, answerability and grounding checks. Ollama uses prompt-based checks. Neither is a trained copy of your judgment.").font(.callout).foregroundStyle(.secondary)
            }
            if configuration.backend == "granite-switch" {
                Text("Requires a Granite Switch GPU server at 127.0.0.1:8000, directly or through an SSH tunnel to your approved server. Uses Guardian, rewriting, answerability, clarification and citation adapters. The existing Mac model stays available as a separate choice.").font(.callout).foregroundStyle(.secondary)
            }
            Text("Bestmate local service URL").font(.caption)
            TextField("Local service URL", text: $configuration.endpoint).textFieldStyle(.roundedBorder)
            HStack {
                Button("Check connection") {
                    if configuration.backend == "openai-compatible" {
                        if modelKey.isEmpty { Keychain.deleteServiceToken(service: configuration.modelKeyService) }
                        else { Keychain.saveServiceToken(service: configuration.modelKeyService, token: modelKey) }
                    }
                    Task {
                        if await controller.check(configuration) {
                            configuration.lastVerifiedAt = Date()
                            store.update { $0.runtime = configuration }
                        }
                    }
                }.buttonStyle(.borderedProminent).disabled(controller.checking)
                Button(configuration.backend == "openai-compatible" ? "Reset connection worker" : configuration.backend == "granite-switch" ? "Reset adapter session" : "Release model memory") { Task { do { try await controller.client.unload(configuration); controller.message = configuration.backend == "openai-compatible" ? "Connection worker reset. Your model server remains running." : configuration.backend == "granite-switch" ? "Adapter worker reset. The separate GPU server is still running." : "Model memory released. The next answer will load it again." } catch { store.error = error.localizedDescription } } }
            }
            Label(controller.message, systemImage: controller.ready ? "checkmark.circle" : "info.circle").font(.callout)
            DisclosureGroup("Start a prepared runtime") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose the local-rag-pilot folder and a Python executable. Model downloads are needed only for the Granite and Ollama retrieval paths; the endpoint option uses local keyword search.").font(.callout).foregroundStyle(.secondary)
                    TextField("Runtime folder", text: $configuration.serviceDirectory).textFieldStyle(.roundedBorder)
                    TextField("Python executable", text: $configuration.pythonExecutable).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Choose folder…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                configuration.serviceDirectory = url.path
                                configuration.pythonExecutable = url.appendingPathComponent(".venv/bin/python").path
                            }
                        }
                        Button("Start service") {
                            do { try controller.launch(configuration); store.update { $0.runtime = configuration } }
                            catch { store.error = error.localizedDescription }
                        }
                        Button("Stop service") {
                            Task {
                                do { try await controller.client.unload(configuration); await controller.stopOwnedService() }
                                catch { store.error = error.localizedDescription }
                            }
                        }
                    }
                    if let log = controller.logPath {
                        Button("Open runtime log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
                    }
                }.padding(.top, 12)
            }
        }.onAppear {
            configuration = store.data.runtime
            modelKey = Keychain.loadServiceToken(service: configuration.modelKeyService) ?? ""
        }.onChange(of: configuration.modelURL) { _ in
            modelKey = Keychain.loadServiceToken(service: configuration.modelKeyService) ?? ""
        }
    }
}

struct WorkspaceKnowledge: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @State private var title = ""
    @State private var text = ""
    @State private var editing: WorkspaceDocument?
    @State private var removing: WorkspaceDocument?
    @State private var findingFiles = false
    var body: some View {
        WorkspaceHeading(eyebrow: "Knowledge", title: "Bring the material you trust.", detail: "Import documents, an Obsidian folder, or notes. New sources are private until you choose to share them.")
        WorkspaceSourceGuidance()
        WorkspacePanel {
            HStack {
                Button("Add documents…") {
                    let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
                    panel.allowedContentTypes = [.plainText, .pdf, UTType(filenameExtension: "md") ?? .plainText]
                    if panel.runModal() == .OK { store.importFiles(panel.urls) }
                }.buttonStyle(.borderedProminent)
                Button("Search a folder…") { findingFiles = true }
                Button("Import Obsidian folder…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { store.importMarkdownFolder(url) }
                }
            }
            DisclosureGroup("Paste a document or notes") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Document title", text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("document-title")
                    TextEditor(text: $text).font(.body).frame(minHeight: 130).border(Color.secondary.opacity(0.2)).accessibilityLabel("Document text").accessibilityIdentifier("document-text")
                    Button("Save on this Mac") { if store.addDocument(title: title, text: text, origin: "Pasted text") { title = ""; text = "" } }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.top, 10)
            }
            Text("Up to 30 sources / 200,000 characters for the current local runtime. Folder imports copy files; they do not continuously sync.").font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $findingFiles) { WorkspaceFileDiscovery() }
        WorkspaceGranola()
        if store.data.documents.isEmpty { Text("No sources yet. One useful document is enough to begin.").foregroundStyle(.secondary) }
        ForEach(store.data.documents) { doc in
            WorkspacePanel {
                HStack { VStack(alignment: .leading) { Text(doc.title).font(.headline); Text(doc.origin).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Edit") { editing = doc }; Button("Remove…", role: .destructive) { removing = doc }.accessibilityLabel("Remove " + doc.title) }
                Toggle("Available for team scopes", isOn: Binding(get: { doc.teamVisible }, set: { shared in store.update { value in if let i = value.documents.firstIndex(where: { $0.id == doc.id }) { value.documents[i].teamVisible = shared } } }))
                DisclosureGroup("Read source") { Text(doc.text).textSelection(.enabled).padding(.top, 8) }
                Text(doc.teamVisible ? "People still need this source in both their own permissions and their twin’s scope." : "Only your owner workspace can use this source.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editing) { doc in WorkspaceDocumentEditor(document: doc) }
        .confirmationDialog("Remove \(removing?.title ?? "this source")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove from workspace", role: .destructive) {
                if let document = removing { _ = store.removeDocument(document.id) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("This stops using the article in future answers and removes its team grants. Your original file is unchanged. Past decisions keep their saved evidence, but decisions based on this article won’t guide new answers.")
        }
    }
}

struct WorkspaceDocumentEditor: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @Environment(\.dismiss) var dismiss
    @State var document: WorkspaceDocument
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit source").font(.title2.bold())
            TextField("Title", text: $document.title)
            TextEditor(text: $document.text).frame(minHeight: 300).accessibilityLabel("Source text")
            Text("Approved decisions with changed evidence will stop being reused until reviewed.").font(.callout).foregroundStyle(.secondary)
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save changes") {
                if store.update({ value in
                    guard !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, document.text.count <= 50_000,
                          value.documents.filter({ $0.id != document.id }).reduce(0, { $0 + $1.text.count }) + document.text.count <= 200_000 else {
                        throw WorkspaceStorageError.invalid("Keep this source within the workspace text limits.")
                    }
                    if let index = value.documents.firstIndex(where: { $0.id == document.id }) { document.modifiedAt = Date(); value.documents[index] = document }
                    value.events.append(WorkspaceEvent(title: "Source updated", detail: document.title))
                }) { dismiss() }
            }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 620)
    }
}

struct WorkspaceReview: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @State private var deferred: Set<UUID> = []
    @State private var reviewFilter = "All reviews"
    var body: some View {
        WorkspaceHeading(eyebrow: "Judgment", title: "Would you make this call?", detail: "One decision at a time. Your explanation and its scope are what make it useful to someone else.")
        let escalationCount = store.data.judgments.filter { $0.status == .draft && store.sharedRequest(for: $0.id) != nil }.count
        Picker("Review queue", selection: $reviewFilter) {
            Text("All reviews").tag("All reviews")
            Text("Escalations (\(escalationCount))").tag("Escalations")
            Text("My practice").tag("My practice")
        }.pickerStyle(.segmented).accessibilityIdentifier("review-queue")
        if reviewFilter == "Escalations" {
            Text("Questions your shared twins brought back to you. Review the proposed answer before it becomes available to the requester.").foregroundStyle(.secondary)
        }
        let drafts = store.data.judgments.filter {
            $0.status == .draft && !deferred.contains($0.id)
            && (reviewFilter == "All reviews" || (store.sharedRequest(for: $0.id) != nil) == (reviewFilter == "Escalations"))
        }
        if let draft = drafts.first {
            Text("\(drafts.count) waiting for you").font(.caption).foregroundStyle(.secondary)
            WorkspaceReviewCard(judgment: draft, deferCard: { deferred.insert(draft.id) }).id(draft.id)
        } else {
            WorkspacePanel {
                Text("You’re caught up.").font(.title2.weight(.semibold))
                Text(reviewFilter == "Escalations" ? "No shared-twin escalations are waiting. Your own practice questions appear in My practice." : "Ask a question using your sources to create a new review card.").foregroundStyle(.secondary)
                if !deferred.isEmpty { Button("Return to deferred cards") { deferred = [] } }
            }
            if reviewFilter != "Escalations" { WorkspaceQuestionBox() }
        }
        if let latest = store.data.judgments.last(where: { $0.status == .approved || $0.status == .rejected }) {
            HStack { Text("Last review: \(latest.status.rawValue)").foregroundStyle(.secondary); Spacer(); Button("Undo review") { store.review(latest.id, status: .undone) } }
        }
    }
}

struct WorkspaceReviewCard: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    let judgment: WorkspaceJudgment
    var deferCard: () -> Void
    @State private var answer = ""
    @State private var reason = ""
    @State private var scope: WorkspaceJudgment.Scope = .instance
    @State private var drag: CGFloat = 0
    @FocusState private var editing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        WorkspacePanel {
            if let request = store.sharedRequest(for: judgment.id) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Shared twin escalation", systemImage: "person.crop.circle.badge.exclamationmark").font(.headline)
                    let personName = store.data.members.first(where: { $0.id == request.memberID })?.name ?? "Former teammate"
                    let twinName = store.data.twins.first(where: { $0.id == request.twinID })?.name ?? "Former twin"
                    Text("From \(personName) · \(twinName)")
                    Text(request.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    Text("The requester can retrieve your approved answer while their access remains valid.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(judgment.topic.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Label("Swipe here to review", systemImage: "hand.draw").font(.caption).foregroundStyle(.secondary)
                }
                Text(judgment.question).font(.system(size: 25, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }.contentShape(Rectangle()).gesture(reviewDrag)
            Text("Proposed answer · editable").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $answer).font(.body).frame(minHeight: 120).focused($editing).accessibilityLabel("Proposed answer").accessibilityIdentifier("review-answer")
            DisclosureGroup("Inspect \(judgment.sourceSnapshots.count) source(s)") {
                ForEach(judgment.sourceSnapshots) { doc in
                    VStack(alignment: .leading, spacing: 6) { Text(doc.title).font(.headline); Text(doc.id.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled); Text(doc.text).font(.callout).textSelection(.enabled) }.padding(.vertical, 8)
                }
            }
            TextField("Why would you make this decision?", text: $reason, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder).accessibilityIdentifier("review-reason")
            Picker("Apply this judgment to", selection: $scope) {
                Text("Only this question").tag(WorkspaceJudgment.Scope.instance)
                Text("This project").tag(WorkspaceJudgment.Scope.project)
                Text("Similar decisions in this topic").tag(WorkspaceJudgment.Scope.similar)
            }
            HStack {
                Button("← No") { store.review(judgment.id, status: .rejected) }
                Button("Needs context") { deferCard() }
                Button("Partly — edit") { editing = true }
                Spacer()
                Button("Yes, approve →") { approve() }.buttonStyle(.borderedProminent)
            }
            Text("Swipe right to approve or left to reject. Add your reasoning before approving. These decisions guide retrieval; they do not fine-tune model weights.").font(.caption).foregroundStyle(.secondary)
        }
        .offset(x: reduceMotion ? 0 : drag).rotationEffect(.degrees(reduceMotion ? 0 : Double(drag / 70)))
        .onAppear { answer = judgment.answer; reason = judgment.reason; scope = judgment.scope }
    }
    var reviewDrag: some Gesture {
        DragGesture(minimumDistance: 45).onChanged { value in
            if abs(value.translation.width) > abs(value.translation.height) * 1.5 { drag = value.translation.width * 0.3 }
        }.onEnded { value in
            drag = 0
            guard abs(value.translation.width) > 140, abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
            if value.translation.width > 0 { approve() } else { store.review(judgment.id, status: .rejected) }
        }
    }
    func approve() { store.approve(judgment.id, answer: answer, reason: reason, scope: scope) }
}

struct WorkspaceHistory: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    var body: some View {
        WorkspaceHeading(eyebrow: "History", title: "How your thinking changed.", detail: "Decisions retain the evidence you reviewed. Revisions and undone approvals stay in the record.")
        ForEach(Array(store.data.judgments.reversed())) { judgment in
            WorkspacePanel {
                HStack { Text(judgment.question).font(.headline); Spacer(); Text(judgment.status.rawValue).font(.caption) }
                Text(judgment.answer).textSelection(.enabled)
                Text(judgment.reason).foregroundStyle(.secondary)
                Text("\(judgment.scope.title) · \(judgment.createdAt.formatted())").font(.caption).foregroundStyle(.secondary)
                if judgment.status != .draft { Button("Create revision") { store.revision(judgment); store.notice = "Revision added to Review." } }
            }
        }
        ForEach(Array(store.data.events.reversed())) { event in
            HStack(alignment: .top) { Text(event.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading); VStack(alignment: .leading) { Text(event.title).font(.headline); Text(event.detail).foregroundStyle(.secondary) } }
        }
    }
}
