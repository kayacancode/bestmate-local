import Foundation

/// Independent of the legacy cloud account. All references are workspace-local IDs.
struct LocalWorkspaceData: Codable, Equatable {
    var schemaVersion = 1
    var id = UUID()
    var name = "My workspace"
    var ownerName = "Me"
    var purpose: WorkspacePurpose?
    var onboardingStep = 0
    var onboardingComplete = false
    var runtime = WorkspaceRuntimeConfiguration()
    var documents: [WorkspaceDocument] = []
    var judgments: [WorkspaceJudgment] = []
    var members: [LocalWorkspaceMember] = []
    var twins: [WorkspaceTwin] = []
    var skills: [WorkspaceSkill] = []
    var consultations: [WorkspaceConsultation] = []
    var events: [WorkspaceEvent] = []
    var whatsAppRoutes: [WorkspaceWhatsAppRoute]? = []
    var telegramRoutes: [WorkspaceTelegramRoute]? = []
    var slackRoutes: [WorkspaceSlackRoute]? = []
    var credentials: [WorkspaceCredential]? = []
}

struct WorkspaceCredential: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var memberID: UUID
    var twinID: UUID
    var tokenHash: String
    var createdAt = Date()
}

struct WorkspaceRuntimeConfiguration: Codable, Equatable {
    var endpoint = "http://127.0.0.1:4390"
    var backend = "granite-hf-adapters"
    var pythonExecutable = ""
    var serviceDirectory = ""
    var lastVerifiedAt: Date?
}

struct WorkspaceDocument: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var text: String
    var origin: String
    var externalID: String? = nil
    var teamVisible = false
    var addedAt = Date()
    var modifiedAt = Date()
}

struct WorkspaceJudgment: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case draft, approved, rejected, undone, superseded }
    enum Scope: String, Codable, CaseIterable {
        case instance, project, similar
        var title: String {
            switch self { case .instance: return "Only this question"; case .project: return "This project"; case .similar: return "Similar decisions in this topic" }
        }
    }
    var id = UUID()
    var question: String
    var answer: String
    var reason: String
    var sourceIDs: [UUID]
    /// Capture the evidence as reviewed, so later source edits cannot rewrite provenance.
    var sourceSnapshots: [WorkspaceDocument]
    var scope: Scope = .instance
    var status: Status = .draft
    var topic: String
    var createdAt = Date()
    var reviewedAt: Date?
    var supersedes: UUID?
}

struct LocalWorkspaceMember: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var role: String
    var sourceIDs: Set<UUID> = []
    var topics: Set<String> = []
    var canAsk = true
    var canReadEvidence = false
    var canProposeCorrections = false
    var canManageAccess = false
}

struct WorkspaceTwin: Codable, Equatable, Identifiable {
    enum Verbosity: String, Codable, CaseIterable { case brief, standard, detailed }
    var id = UUID()
    var name: String
    var purpose: String
    var memberIDs: Set<UUID> = []
    var sourceIDs: Set<UUID> = []
    var topics: Set<String> = []
    var suggestedSubjects: [String]?
    var skillID: UUID?
    var verbosity: Verbosity = .standard
    var requiresOwnerReview = true
    var enabled = true
    /// Calendar weekdays: Sunday=1, Monday=2, ... Saturday=7.
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var startMinute = 9 * 60
    var endMinute = 17 * 60
    var timeZone = TimeZone.current.identifier
}

struct WorkspaceSkill: Codable, Equatable, Identifiable {
    enum Trigger: String, Codable, CaseIterable { case question, daily, weekly }
    var id = UUID()
    var name: String
    var instructions: String
    var trigger: Trigger = .question
    var weekday = 6
    var minute = 16 * 60
    var timeZone = TimeZone.current.identifier
    var enabled = false
    var lastRunAt: Date?
    var latestDraft: String?
}

struct WorkspaceConsultation: Codable, Equatable, Identifiable {
    enum Outcome: String, Codable {
        case answered, denied, outsideHours, needsContext, needsReview, failed
        var title: String {
            switch self {
            case .answered: return "Answered"
            case .denied: return "Access denied"
            case .outsideHours: return "Outside available hours"
            case .needsContext: return "Needs more context"
            case .needsReview: return "Needs your review"
            case .failed: return "Could not answer"
            }
        }
    }
    var id = UUID()
    var memberID: UUID?
    var twinID: UUID?
    var topic: String
    var question: String
    var answer: String
    var outcome: Outcome
    var sourceIDs: [UUID]
    var judgmentIDs: [UUID] = []
    var reviewID: UUID?
    var createdAt = Date()
    var seconds: Double = 0
}

struct WorkspaceEvent: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var detail: String
    var createdAt = Date()
}

/// Applies before constructing the retrieval corpus, including owner-approved decisions.
enum WorkspaceAccessPolicy {
    static func sharedSubjects(member: LocalWorkspaceMember?, twin: WorkspaceTwin?) -> [String] {
        guard let member, let twin, twin.memberIDs.contains(member.id) else { return [] }
        if member.topics.isEmpty && twin.topics.isEmpty { return ["General"] }
        if member.topics.isEmpty { return twin.topics.sorted() }
        if twin.topics.isEmpty { return member.topics.sorted() }
        return member.topics.intersection(twin.topics).sorted()
    }

    enum Decision: Equatable {
        case allowed(Set<UUID>)
        case denied(String)
        case outsideHours
    }

    static func evaluate(member: LocalWorkspaceMember, twin: WorkspaceTwin,
                         documents: [WorkspaceDocument], topic: String, at date: Date) -> Decision {
        guard twin.enabled, member.canAsk, twin.memberIDs.contains(member.id) else {
            return .denied("This person cannot consult this twin.")
        }
        guard (member.topics.isEmpty || member.topics.contains(topic)), (twin.topics.isEmpty || twin.topics.contains(topic)) else {
            return .denied("This subject is not allowed for both the person and twin. Choose a shared allowed subject, or update their permissions in Team.")
        }
        guard let zone = TimeZone(identifier: twin.timeZone) else {
            return .denied("The twin has an invalid time zone.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let weekday = calendar.component(.weekday, from: date)
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let previousDay = weekday == 1 ? 7 : weekday - 1
        let available: Bool
        if twin.startMinute < twin.endMinute {
            available = twin.weekdays.contains(weekday) && minute >= twin.startMinute && minute < twin.endMinute
        } else if twin.startMinute > twin.endMinute {
            available = (twin.weekdays.contains(weekday) && minute >= twin.startMinute) ||
                (twin.weekdays.contains(previousDay) && minute < twin.endMinute)
        } else { available = false }
        guard available else { return .outsideHours }
        let shared = Set(documents.filter(\.teamVisible).map(\.id))
        let allowed = member.sourceIDs.intersection(twin.sourceIDs).intersection(shared)
        guard !allowed.isEmpty else { return .denied("There is no knowledge available to both this person and this twin.") }
        return .allowed(allowed)
    }

    static func judgments(_ judgments: [WorkspaceJudgment], permittedSources: Set<UUID>, topic: String) -> [WorkspaceJudgment] {
        judgments.filter {
            $0.status == .approved && $0.scope != .instance && $0.topic == topic &&
            !$0.sourceIDs.isEmpty && Set($0.sourceIDs).isSubset(of: permittedSources)
        }
    }
}
