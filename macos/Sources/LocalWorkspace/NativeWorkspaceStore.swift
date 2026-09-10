import Foundation
import SwiftUI
import PDFKit

@MainActor
final class NativeWorkspaceStore: ObservableObject {
    @Published private(set) var data: LocalWorkspaceData
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var storageReady = true
    @Published private(set) var working = false
    @Published var questionStartedAt: Date?
    @Published var questionProgress: [WorkspaceRuntimeProgress.Event] = []
    @Published var progressUnavailable = false
    @Published var lastAnswer: WorkspaceConsultation?
    let runtime = WorkspaceRuntimeController()
    let gateway = WorkspaceGateway()
    let slack = WorkspaceSlackConnection()
    let telegram = WorkspaceTelegramConnection()
    let whatsApp = WorkspaceWhatsAppConnection()
    private struct Conversation {
        var corpus: [WorkspaceDocument]
        var member: LocalWorkspaceMember?
        var twin: WorkspaceTwin?
        var turns: [[String: String]] = []
    }
    private var conversations: [String: Conversation] = [:]
    var answering: WorkspaceAnswering?
    let repository: WorkspaceRepository

    init(repository: WorkspaceRepository = WorkspaceRepository()) {
        self.repository = repository
        do { data = try repository.load() }
        catch { data = LocalWorkspaceData(); self.error = error.localizedDescription; storageReady = false }
    }

    @discardableResult
    func saveSlackMapping(channel: String, sender: String, memberID: UUID?, twinID: UUID, subject: String) -> Bool {
        let channel = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        return update { value in
            guard channel.range(of: "^[CG][A-Z0-9]+$", options: .regularExpression) != nil,
                  sender.isEmpty || sender.range(of: "^[UW][A-Z0-9]+$", options: .regularExpression) != nil,
                  let twinIndex = value.twins.firstIndex(where: { $0.id == twinID }) else {
                throw WorkspaceStorageError.invalid("Enter a Slack channel ID and choose a twin. The Slack member ID is optional.")
            }
            var routes = value.slackRoutes ?? []
            let previous = routes.first { $0.channelID == channel && $0.slackUserID == sender }
            let audience: UUID
            let ownsAudience: Bool
            if let memberID, !sender.isEmpty {
                guard let person = value.members.first(where: { $0.id == memberID }),
                      WorkspaceAccessPolicy.sharedSubjects(member: person, twin: value.twins[twinIndex]).contains(subject) else {
                    throw WorkspaceStorageError.invalid("This person needs access to the selected twin and subject.")
                }
                audience = memberID; ownsAudience = false
            } else {
                let twin = value.twins[twinIndex]
                guard twin.topics.isEmpty || twin.topics.contains(subject) else { throw WorkspaceStorageError.invalid("Choose a subject allowed by this twin.") }
                let sources = twin.sourceIDs.intersection(Set(value.documents.filter(\.teamVisible).map(\.id)))
                guard !sources.isEmpty else { throw WorkspaceStorageError.invalid("Select at least one shared source for this twin first.") }
                var person = LocalWorkspaceMember(name: "Slack channel " + channel + (sender.isEmpty ? "" : " · " + sender), role: "Channel audience")
                if previous?.ownsAudience == true, let id = previous?.memberID, value.members.contains(where: { $0.id == id }) { person.id = id }
                person.sourceIDs = sources; person.topics = twin.topics; person.canReadEvidence = false
                if let index = value.members.firstIndex(where: { $0.id == person.id }) { value.members[index] = person } else { value.members.append(person) }
                value.twins[twinIndex].memberIDs.insert(person.id)
                audience = person.id; ownsAudience = true
            }
            routes.removeAll { $0.channelID == channel && $0.slackUserID == sender }
            routes.append(WorkspaceSlackRoute(channelID: channel, slackUserID: sender, memberID: audience, twinID: twinID, topic: subject, ownsAudience: ownsAudience))
            value.slackRoutes = routes
            value.events.append(WorkspaceEvent(title: "Slack channel mapped", detail: channel + (sender.isEmpty ? " · channel audience" : " · individual sender")))
        }
    }

    func saveTelegramMapping(channel: String, sender: String, memberID: UUID?, twinID: UUID, subject: String) -> Bool {
        let channel = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        return update { value in
            guard channel.range(of: "^-?[1-9][0-9]{0,15}$", options: .regularExpression) != nil,
                  sender.isEmpty || sender.range(of: "^[1-9][0-9]{0,15}$", options: .regularExpression) != nil,
                  let twinIndex = value.twins.firstIndex(where: { $0.id == twinID }) else {
                throw WorkspaceStorageError.invalid("Enter a Telegram channel ID and choose a twin. The Telegram member ID is optional.")
            }
            var routes = value.telegramRoutes ?? []
            let previous = routes.first { $0.chatID == channel && $0.senderID == sender }
            let audience: UUID
            let ownsAudience: Bool
            if let memberID, !sender.isEmpty {
                guard let person = value.members.first(where: { $0.id == memberID }),
                      WorkspaceAccessPolicy.sharedSubjects(member: person, twin: value.twins[twinIndex]).contains(subject) else {
                    throw WorkspaceStorageError.invalid("This person needs access to the selected twin and subject.")
                }
                audience = memberID; ownsAudience = false
            } else {
                let twin = value.twins[twinIndex]
                guard twin.topics.isEmpty || twin.topics.contains(subject) else { throw WorkspaceStorageError.invalid("Choose a subject allowed by this twin.") }
                let sources = twin.sourceIDs.intersection(Set(value.documents.filter(\.teamVisible).map(\.id)))
                guard !sources.isEmpty else { throw WorkspaceStorageError.invalid("Select at least one shared source for this twin first.") }
                var person = LocalWorkspaceMember(name: "Telegram channel " + channel + (sender.isEmpty ? "" : " · " + sender), role: "Channel audience")
                if previous?.ownsAudience == true, let id = previous?.memberID, value.members.contains(where: { $0.id == id }) { person.id = id }
                person.sourceIDs = sources; person.topics = twin.topics; person.canReadEvidence = false
                if let index = value.members.firstIndex(where: { $0.id == person.id }) { value.members[index] = person } else { value.members.append(person) }
                value.twins[twinIndex].memberIDs.insert(person.id)
                audience = person.id; ownsAudience = true
            }
            routes.removeAll { $0.chatID == channel && $0.senderID == sender }
            routes.append(WorkspaceTelegramRoute(chatID: channel, senderID: sender, memberID: audience, twinID: twinID, topic: subject, ownsAudience: ownsAudience))
            value.telegramRoutes = routes
            value.events.append(WorkspaceEvent(title: "Telegram channel mapped", detail: channel + (sender.isEmpty ? " · channel audience" : " · individual sender")))
        }
    }

    @discardableResult
    func update(_ mutation: (inout LocalWorkspaceData) throws -> Void) -> Bool {
        guard storageReady else { error = WorkspaceStorageError.readOnly.localizedDescription; return false }
        do {
            var next = data
            try mutation(&next)
            try repository.save(next)
            data = next
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func log(_ title: String, _ detail: String, into value: inout LocalWorkspaceData) {
        value.events.append(WorkspaceEvent(title: title, detail: detail))
    }

    @discardableResult
    func addDocument(title: String, text: String, origin: String, teamVisible: Bool = false) -> Bool {
        update { value in
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, content.count <= 50_000 else {
                throw WorkspaceStorageError.invalid("Choose a document with text, up to 50,000 characters.")
            }
            guard value.documents.count < 30, value.documents.reduce(0, { $0 + $1.text.count }) + content.count <= 200_000 else {
                throw WorkspaceStorageError.invalid("This local workspace currently supports 30 documents and 200,000 characters.")
            }
            let doc = WorkspaceDocument(title: title.isEmpty ? "Untitled" : title, text: content, origin: origin, teamVisible: teamVisible)
            value.documents.append(doc)
            log("Knowledge added", doc.title, into: &value)
        }
    }

    @discardableResult
    func removeDocument(_ id: UUID) -> Bool {
        update { value in
            guard let document = value.documents.first(where: { $0.id == id }) else { return }
            value.documents.removeAll { $0.id == id }
            for index in value.members.indices { value.members[index].sourceIDs.remove(id) }
            for index in value.twins.indices { value.twins[index].sourceIDs.remove(id) }
            log("Source removed", document.title, into: &value)
        }
    }

    @discardableResult
    func importDiscoveredSources(_ sources: [WorkspaceDocument]) -> Bool {
        guard !sources.isEmpty else { return false }
        return update { value in
            for source in sources {
                guard let externalID = source.externalID, externalID.hasPrefix("local-file:"),
                      !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      source.text.count <= 50_000 else {
                    throw WorkspaceStorageError.invalid("Choose a readable source with up to 50,000 characters.")
                }
                if let index = value.documents.firstIndex(where: { $0.externalID == externalID }) {
                    if value.documents[index].text != source.text || value.documents[index].title != source.title {
                        value.documents[index].text = source.text
                        value.documents[index].title = source.title
                        value.documents[index].origin = source.origin
                        value.documents[index].modifiedAt = Date()
                    }
                } else {
                    var document = source
                    document.teamVisible = false
                    value.documents.append(document)
                }
            }
            guard value.documents.count <= 30, value.documents.reduce(0, { $0 + $1.text.count }) <= 200_000 else {
                throw WorkspaceStorageError.invalid("Select fewer files: this workspace supports 30 sources and 200,000 characters.")
            }
            log("Files imported", "Imported \(sources.count) selected file snapshots.", into: &value)
        }
    }

    @discardableResult
    func importGranolaNotes(_ notes: [(id: String, title: String, text: String)]) -> Bool {
        update { value in
            for note in notes {
                let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 50_000 else { throw WorkspaceStorageError.invalid("Each note needs text and must be under 50,000 characters.") }
                let externalID = "granola:" + note.id
                if let index = value.documents.firstIndex(where: { $0.externalID == externalID }) {
                    if value.documents[index].text != text || value.documents[index].title != note.title {
                        value.documents[index].text = text
                        value.documents[index].title = note.title
                        value.documents[index].modifiedAt = Date()
                    }
                } else {
                    var document = WorkspaceDocument(title: note.title, text: text, origin: "Granola")
                    document.externalID = externalID
                    value.documents.append(document)
                }
            }
            guard value.documents.count <= 30, value.documents.reduce(0, { $0 + $1.text.count }) <= 200_000 else {
                throw WorkspaceStorageError.invalid("Choose fewer notes: this workspace supports 30 sources and 200,000 characters.")
            }
            log("Notes imported", "Downloaded \(notes.count) selected notes from Granola.", into: &value)
        }
    }

    func importFiles(_ urls: [URL]) {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let text: String
                if url.pathExtension.lowercased() == "pdf" {
                    guard let document = PDFDocument(url: url), let content = document.string else {
                        throw WorkspaceStorageError.invalid("This PDF has no selectable text. Export a text version first.")
                    }
                    text = content
                } else { text = try String(contentsOf: url, encoding: .utf8) }
                guard addDocument(title: url.deletingPathExtension().lastPathComponent, text: text, origin: url.lastPathComponent) else { return }
            } catch { self.error = "\(url.lastPathComponent): \(error.localizedDescription)"; return }
        }
        notice = "Documents saved on this Mac. No upload was made."
    }

    func importMarkdownFolder(_ url: URL) {
        guard data.documents.count < 30 else { error = "The workspace has reached its 30-document limit."; return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            error = "The folder could not be read."; return
        }
        var files: [URL] = []
        for case let item as URL in entries {
            if ["md", "txt"].contains(item.pathExtension.lowercased()) {
                files.append(item)
                if files.count >= 30 - data.documents.count { break }
            }
        }
        guard !files.isEmpty else { error = "No Markdown or text files were found in this folder."; return }
        importFiles(files)
    }

    func approve(_ id: UUID, answer: String, reason: String, scope: WorkspaceJudgment.Scope) {
        update { value in
            guard let index = value.judgments.firstIndex(where: { $0.id == id }) else { return }
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkspaceStorageError.invalid("Add your decision and its reasoning before approving it.")
            }
            guard value.judgments[index].status == .draft else {
                throw WorkspaceStorageError.invalid("Create a revision to change an already reviewed judgment.")
            }
            guard answer.count + reason.count + value.judgments[index].question.count <= 3000 else {
                throw WorkspaceStorageError.invalid("Keep the question, decision and reason within 3,000 characters so this judgment fits the local model context.")
            }
            if let previous = value.judgments[index].supersedes,
               value.judgments.first(where: { $0.id == previous })?.status == .superseded {
                throw WorkspaceStorageError.invalid("A newer revision was approved. Revise that version instead.")
            }
            value.judgments[index].answer = answer
            value.judgments[index].reason = reason
            value.judgments[index].scope = scope
            value.judgments[index].status = .approved
            value.judgments[index].reviewedAt = Date()
            if let previous = value.judgments[index].supersedes,
               let old = value.judgments.firstIndex(where: { $0.id == previous }), value.judgments[old].status == .approved {
                value.judgments[old].status = .superseded
            }
            for i in value.consultations.indices where value.consultations[i].reviewID == id {
                value.consultations[i].answer = answer
                value.consultations[i].outcome = .answered
                value.consultations[i].judgmentIDs = [id]
            }
            log("Judgment approved", value.judgments[index].question, into: &value)
        }
    }

    func review(_ id: UUID, status: WorkspaceJudgment.Status) {
        update { value in
            guard let index = value.judgments.firstIndex(where: { $0.id == id }) else { return }
            guard status == .rejected || status == .undone else { return }
            guard (status == .rejected && value.judgments[index].status == .draft) ||
                    (status == .undone && [.approved, .rejected].contains(value.judgments[index].status)) else {
                throw WorkspaceStorageError.invalid("This review has changed. Open its latest version before undoing it.")
            }
            value.judgments[index].status = status
            value.judgments[index].reviewedAt = Date()
            for i in value.consultations.indices where value.consultations[i].reviewID == id {
                value.consultations[i].outcome = .needsReview
            }
            if status == .undone, let previous = value.judgments[index].supersedes,
               let old = value.judgments.firstIndex(where: { $0.id == previous }), value.judgments[old].status == .superseded {
                value.judgments[old].status = .approved
            }
            log(status == .undone ? "Judgment approval undone" : "Judgment rejected", value.judgments[index].question, into: &value)
        }
    }

    func revision(_ judgment: WorkspaceJudgment) {
        update { value in
            var next = judgment
            next.id = UUID(); next.supersedes = judgment.id; next.status = .draft
            next.createdAt = Date(); next.reviewedAt = nil
            next.sourceSnapshots = value.documents.filter { judgment.sourceIDs.contains($0.id) }
            value.judgments.append(next)
        }
    }

    func sharedRequest(for judgmentID: UUID) -> WorkspaceConsultation? {
        data.consultations.last { $0.reviewID == judgmentID && ($0.memberID != nil || $0.twinID != nil) }
    }

    func evidenceIsCurrent(_ judgment: WorkspaceJudgment) -> Bool {
        !judgment.sourceIDs.isEmpty && judgment.sourceIDs.allSatisfy { id in
            guard let current = data.documents.first(where: { $0.id == id }),
                  let original = judgment.sourceSnapshots.first(where: { $0.id == id }) else { return false }
            return current.text == original.text
        }
    }

    func suggestSubjects(_ documents: [WorkspaceDocument]) async -> [String]? {
        guard !working, !documents.isEmpty else { return nil }
        working = true
        defer { working = false }
        do {
            let excerpts = documents.prefix(30).map { doc -> WorkspaceDocument in
                var copy = doc; copy.text = String(doc.text.prefix(1200)); return copy
            }
            let result = try await runtime.client.askWithProgress("Suggest subjects", documents: excerpts, configuration: data.runtime, verbosity: .brief, subjects: true) { _ in }
            guard result.status == "answered", let labels = try? JSONDecoder().decode([String].self, from: Data(result.answer.utf8)), !labels.isEmpty, labels.count <= 6,
                  labels.allSatisfy({ !$0.isEmpty && $0.count <= 60 }) else {
                error = "The model couldn't suggest subjects this time. You can save without them."; return nil
            }
            return labels
        } catch { self.error = "Subject suggestions are unavailable. You can save without them."; return nil }
    }

    /// Owner-only source advice. No grants, decisions, or consultations are created.
    func suggestSources(_ documents: [WorkspaceDocument], for purpose: WorkspacePurpose) async -> WorkspaceSourceSuggestion? {
        guard !working else { error = "A local request is already running."; return nil }
        guard !documents.isEmpty, documents.count <= 30,
              documents.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 50_000 }),
              documents.reduce(0, { $0 + $1.text.count }) <= 200_000 else {
            error = "Choose up to 30 sources and 200,000 characters for local source suggestions."; return nil
        }
        working = true
        defer { working = false }
        do {
            let question = purpose.sourceQuestion
            let response = try await (answering ?? runtime.client).ask(question, documents: documents, configuration: data.runtime, verbosity: .standard)
            try Task.checkCancellation()
            let ids = Set(response.sources.compactMap { UUID(uuidString: $0.id) })
            let answer = response.answer.lowercased()
            let sources = response.status == "answered" ? documents.filter {
                ids.contains($0.id) && answer.contains("[" + $0.id.uuidString.lowercased() + "]")
            } : []
            return WorkspaceSourceSuggestion(explanation: response.answer, sources: sources)
        } catch { self.error = error.localizedDescription; return nil }
    }

    /// The same entry point is used by the owner, teammate preview and scoped agent gateway.
    /// Corpus filtering happens before the service receives any text.
    @discardableResult
    func consult(question: String, topic: String, memberID: UUID? = nil, twinID: UUID? = nil,
                 makeReview: Bool = false, conversationID: String? = nil) async -> WorkspaceConsultation? {
        guard !working else { error = "A local question is already running."; return nil }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 2000, !topic.isEmpty else {
            error = "Enter a topic and a question of up to 2,000 characters."; return nil
        }
        let start = Date()
        let conversationKey = conversationID.map { $0 + "|" + (memberID?.uuidString ?? "owner") + "|" + (twinID?.uuidString ?? "owner") + "|" + topic }
        var pendingConversation: Conversation?
        var documents = data.documents
        var twin: WorkspaceTwin?
        var member: LocalWorkspaceMember?
        var denied: WorkspaceConsultation.Outcome?
        var denial = ""
        if memberID != nil || twinID != nil {
            member = data.members.first { $0.id == memberID }
            twin = data.twins.first { $0.id == twinID }
            if let person = member, let version = twin {
                switch WorkspaceAccessPolicy.evaluate(member: person, twin: version, documents: documents, topic: topic, at: start) {
                case .allowed(let ids): documents = documents.filter { ids.contains($0.id) }
                case .denied(let reason): denied = .denied; denial = reason
                case .outsideHours: denied = .outsideHours; denial = "This twin is outside its available hours."
                }
            } else { denied = .denied; denial = "This person or twin is no longer available." }
        }
        var record = WorkspaceConsultation(memberID: memberID, twinID: twinID, topic: topic, question: question,
                                           answer: denial, outcome: denied ?? .failed, sourceIDs: [])
        if denied == nil {
            guard !documents.isEmpty else { error = "Add knowledge before asking a question."; return nil }
            working = true
            questionStartedAt = start; questionProgress = []; progressUnavailable = false
            defer { working = false; questionStartedAt = nil }
            let approved = WorkspaceAccessPolicy.judgments(data.judgments, permittedSources: Set(documents.map(\.id)), topic: topic)
                .filter { evidenceIsCurrent($0) }.sorted { ($0.reviewedAt ?? $0.createdAt) < ($1.reviewedAt ?? $1.createdAt) }
            // Approved decisions are distinct evidence, with their own immutable identifiers.
            let decisions = approved.suffix(30).map { judgment in
                WorkspaceDocument(id: judgment.id, title: "Owner-approved judgment: " + String(judgment.question.prefix(120)),
                                  text: "Scope: \(judgment.scope.rawValue). Question: \(judgment.question)\nDecision: \(judgment.answer)\nReason: \(judgment.reason)", origin: "Approved judgment")
            }
            do {
                let corpus = documents + decisions
                var conversation = Conversation(corpus: corpus, member: member, twin: twin)
                if let key = conversationKey, let old = conversations[key], old.corpus == corpus, old.member == member, old.twin == twin {
                    conversation = old
                }
                pendingConversation = conversation
                if approved.count > 30 { notice = "This question uses the 30 latest eligible judgments for its topic. Earlier versions remain in History." }
                let skill = data.skills.first { $0.id == twin?.skillID && $0.trigger == .question }
                let guidance = [twin?.purpose, skill?.instructions].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                let requestQuestion = guidance.isEmpty ? question : "Purpose and task: \(guidance)\nQuestion: \(question)"
                guard requestQuestion.count <= 2000 else {
                    throw WorkspaceStorageError.invalid("Shorten the question, twin purpose or skill instructions to fit the 2,000-character request limit.")
                }
                let answer: WorkspaceRuntimeAnswer
                if let answering {
                    answer = try await answering.ask(requestQuestion, documents: corpus, configuration: data.runtime, verbosity: twin?.verbosity ?? .standard)
                } else {
                    answer = try await runtime.client.askWithProgress(requestQuestion, documents: corpus, configuration: data.runtime, verbosity: twin?.verbosity ?? .standard, scope: String(([twin?.purpose ?? data.purpose?.topic ?? ""] + documents.map(\.title)).joined(separator: "; ").prefix(4000)), history: conversation.turns) { [weak self] update in
                        guard let self, self.questionStartedAt == start else { return }
                        self.progressUnavailable = update == nil
                        if let update { self.questionProgress = update.events }
                    }
                }
                // Access or source content can change while inference is running. Never deliver a stale grant.
                if let oldMember = member, let oldTwin = twin {
                    guard data.members.first(where: { $0.id == oldMember.id }) == oldMember,
                          data.twins.first(where: { $0.id == oldTwin.id }) == oldTwin,
                          case .allowed = WorkspaceAccessPolicy.evaluate(member: oldMember, twin: oldTwin, documents: data.documents, topic: topic, at: Date()) else {
                        throw WorkspaceStorageError.invalid("Access changed while the answer was being prepared. Ask again with the current permissions.")
                    }
                }
                guard documents.allSatisfy({ original in data.documents.contains(where: { $0.id == original.id && $0.text == original.text && $0.teamVisible == original.teamVisible }) }),
                      approved.allSatisfy({ original in data.judgments.contains(original) }) else {
                    throw WorkspaceStorageError.invalid("The evidence changed during this question. Ask again using the current knowledge.")
                }
                record.answer = answer.answer
                record.outcome = answer.status == "answered" ? .answered : ["needs_context", "needs_clarification"].contains(answer.status) ? .needsContext : answer.status == "blocked" ? .denied : .needsReview
                let cited = Set(answer.sources.compactMap { UUID(uuidString: $0.id) })
                record.sourceIDs = documents.filter { cited.contains($0.id) }.map(\.id)
                record.judgmentIDs = approved.filter { cited.contains($0.id) }.map(\.id)
                if twin?.requiresOwnerReview == true && record.outcome == .answered { record.outcome = .needsReview }
                if makeReview || record.outcome == .needsReview {
                    let sourceIDs = Array(Set(record.sourceIDs + approved.filter { record.judgmentIDs.contains($0.id) }.flatMap(\.sourceIDs)))
                    let draft = WorkspaceJudgment(question: question, answer: answer.answer, reason: "", sourceIDs: sourceIDs,
                                                  sourceSnapshots: documents.filter { sourceIDs.contains($0.id) }, topic: topic)
                    record.reviewID = draft.id
                    record.sourceIDs = sourceIDs
                    guard update({ $0.judgments.append(draft) }) else { throw WorkspaceStorageError.invalid("The review draft could not be saved.") }
                }
            } catch { record.outcome = .failed; record.answer = error.localizedDescription }
        }
        record.seconds = Date().timeIntervalSince(start)
        guard update({ $0.consultations.append(record) }) else { return nil }
        lastAnswer = record
        // The owner can inspect the stored draft. A teammate receives only the review receipt.
        if memberID != nil && record.outcome == .needsReview {
            record.answer = "This question needs the owner's review. A draft is waiting in their review inbox."
            record.sourceIDs = []; record.judgmentIDs = []
        } else if member?.canReadEvidence == false {
            record.sourceIDs = []; record.judgmentIDs = []
        }
        if data.runtime.backend == "granite-switch", let key = conversationKey, var conversation = pendingConversation,
           record.outcome != .failed && record.outcome != .denied && record.outcome != .outsideHours {
            conversation.turns += [["role": "user", "content": question], ["role": "assistant", "content": String(record.answer.prefix(4000))]]
            conversation.turns = Array(conversation.turns.suffix(12))
            if conversations.count >= 64 && conversations[key] == nil { conversations.removeAll() }
            conversations[key] = conversation
        }
        return record
    }

    /// Re-check access when an agent retrieves an answer that was held for owner review.
    func consultationReceipt(_ id: UUID, memberID: UUID, twinID: UUID) -> WorkspaceConsultation? {
        guard var record = data.consultations.first(where: { $0.id == id && $0.memberID == memberID && $0.twinID == twinID }),
              let member = data.members.first(where: { $0.id == memberID }), let twin = data.twins.first(where: { $0.id == twinID }),
              case .allowed(let sources) = WorkspaceAccessPolicy.evaluate(member: member, twin: twin, documents: data.documents, topic: record.topic, at: Date()),
              Set(record.sourceIDs).isSubset(of: sources) else { return nil }
        if let reviewID = record.reviewID {
            guard let review = data.judgments.first(where: { $0.id == reviewID }), review.status == .approved,
                  Set(review.sourceIDs).isSubset(of: sources), evidenceIsCurrent(review) else {
                record.outcome = .needsReview; record.answer = "This answer still needs the owner's review."
                record.sourceIDs = []; record.judgmentIDs = []; return record
            }
        } else { return nil } // Only immutable, reviewed answers are available for later collection.
        if !member.canReadEvidence { record.sourceIDs = []; record.judgmentIDs = [] }
        return record
    }

    func runSkill(_ id: UUID) async {
        guard let skill = data.skills.first(where: { $0.id == id }), !working else { return }
        guard let result = await consult(question: skill.instructions, topic: skill.name, makeReview: true) else { return }
        update { value in
            if let i = value.skills.firstIndex(where: { $0.id == id }) {
                value.skills[i].lastRunAt = Date()
                value.skills[i].latestDraft = result.answer
            }
            value.events.append(WorkspaceEvent(title: "Skill ran locally", detail: skill.name))
        }
    }

    func runDueSkills(at now: Date = Date()) async {
        guard !working else { return }
        for skill in data.skills where skill.enabled && skill.trigger != .question {
            guard let due = Self.latestOccurrence(skill, at: now), skill.lastRunAt == nil || skill.lastRunAt! < due else { continue }
            await runSkill(skill.id)
        }
    }

    static func latestOccurrence(_ skill: WorkspaceSkill, at now: Date) -> Date? {
        guard let zone = TimeZone(identifier: skill.timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var components = DateComponents(hour: skill.minute / 60, minute: skill.minute % 60)
        if skill.trigger == .weekly { components.weekday = skill.weekday }
        return calendar.nextDate(after: now.addingTimeInterval(1), matching: components, matchingPolicy: .nextTime, direction: .backward)
    }
}
