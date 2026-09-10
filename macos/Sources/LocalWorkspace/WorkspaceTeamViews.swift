import SwiftUI

struct WorkspaceTeam: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @State private var tab = "Overview"
    @State private var member: LocalWorkspaceMember?
    @State private var twin: WorkspaceTwin?
    @State private var personFilter: UUID?
    @State private var topicFilter = "All topics"
    @State private var timeFilter = "All time"
    private func overviewMetric(_ title: String, _ count: Int) -> some View {
        WorkspacePanel {
            Text("\(count)").font(.custom("AvenirNext-Medium", size: 30))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
    var body: some View {
        WorkspaceHeading(eyebrow: "Team workspace", title: "Share a considered version of you.", detail: "Choose who can ask, the knowledge they can use, and when a question should come back to you.")
        Picker("Team view", selection: $tab) {
            Text("Overview").tag("Overview")
            Text("People & access").tag("People & access")
            Text("Twins").tag("Twins")
            Text("Questions & analytics").tag("Questions & analytics")
            Text("Channels").tag("Channels")
            Text("Agent access").tag("Agent access")
        }.pickerStyle(.segmented)
        if tab == "Overview" {
            HStack(spacing: 16) {
                overviewMetric("People", store.data.members.count)
                overviewMetric("Questions asked", store.data.consultations.count)
                overviewMetric("Active twins", store.data.twins.filter { $0.enabled }.count)
                overviewMetric("Needs review", store.data.judgments.filter { $0.status == .draft }.count)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    WorkspacePanel {
                        HStack { Text("People & permissions").font(.headline); Spacer(); Button("Add person") { member = LocalWorkspaceMember(name: "", role: "Teammate") } }
                        Text("Who can use your knowledge, and where their access ends.").foregroundStyle(.secondary)
                        if store.data.members.isEmpty { Text("Add a teammate to define their first scope.").foregroundStyle(.secondary) }
                        ForEach(store.data.members) { person in
                            Divider()
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(person.name).font(.headline)
                                    Text(person.topics.sorted().joined(separator: " · ")).font(.caption)
                                    Text("\(person.sourceIDs.count) sources · " + (person.canReadEvidence ? "Evidence access" : "Answers only")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Edit access") { member = person }
                            }
                        }
                    }
                    WorkspacePanel {
                        HStack { Text("Recent questions").font(.headline); Spacer(); Button("Analytics") { tab = "Questions & analytics" } }
                        if store.data.consultations.isEmpty { Text("Questions will appear here as people use your twin.").foregroundStyle(.secondary) }
                        ForEach(Array(store.data.consultations.suffix(5).reversed())) { question in
                            Divider()
                            Text(question.question)
                            Text(question.topic + " · " + question.outcome.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity)
                VStack(spacing: 20) {
                    WorkspacePanel {
                        Text("Versions of you").font(.headline)
                        Text("Give each twin a purpose, audience, and working hours.").foregroundStyle(.secondary)
                        ForEach(store.data.twins) { version in
                            Divider()
                            Text(version.name).font(.headline)
                            Text(version.purpose).foregroundStyle(.secondary)
                    if let labels = version.suggestedSubjects, !labels.isEmpty {
                        Text("Suggested subjects: " + labels.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    if version.memberIDs.isEmpty || version.sourceIDs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Finish setup in Configure").font(.callout.weight(.medium))
                            if version.memberIDs.isEmpty { Label("Choose at least one person", systemImage: "circle") }
                            if version.sourceIDs.isEmpty { Label("Choose at least one shared source", systemImage: "circle") }
                        }.font(.caption)
                    } else { Text(version.topics.isEmpty ? "Access follows selected knowledge" : "Subject restrictions: " + version.topics.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                            Button("Configure") { twin = version }
                        }
                        Button("Build a twin") { twin = WorkspaceTwin(name: "", purpose: "") }.buttonStyle(.borderedProminent)
                    }
                    WorkspacePanel {
                        Text("Knowledge boundaries").font(.headline)
                        Text("\(store.data.documents.filter { $0.teamVisible }.count) of \(store.data.documents.count) sources available for team scopes.")
                        Text("Every answer must fit both the person’s permissions and their twin’s scope.").foregroundStyle(.secondary)
                        Button("Manage agent access") { tab = "Agent access" }
                    }
                }.frame(width: 280)
            }
        } else if tab == "People & access" {
            HStack { Text("\(store.data.members.count) \(store.data.members.count == 1 ? "person" : "people")").font(.headline); Spacer(); Button("Add person") { member = LocalWorkspaceMember(name: "", role: "Teammate") }.buttonStyle(.borderedProminent) }
            Text("Adding a person creates a local access profile. It does not send an invitation.").font(.callout).foregroundStyle(.secondary)
            ForEach(store.data.members) { person in
                WorkspacePanel {
                    HStack { VStack(alignment: .leading, spacing: 4) { Text(person.name).font(.title3.weight(.semibold)); Text(person.role).foregroundStyle(.secondary) }; Spacer(); Button("Edit access") { member = person } }
                    Text(person.topics.sorted().joined(separator: " · ")).font(.callout)
                    HStack {
                        Label("\(person.sourceIDs.count) source grants", systemImage: "doc.on.doc")
                        Label(person.canAsk ? "Can ask" : "Asking revoked", systemImage: person.canAsk ? "checkmark.circle" : "minus.circle")
                        Text(person.canReadEvidence ? "Can read evidence" : "Answers only")
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if tab == "Twins" {
            HStack { Text("\(store.data.twins.count) \(store.data.twins.count == 1 ? "version" : "versions")").font(.headline); Spacer(); Button("Build a twin") { twin = WorkspaceTwin(name: "", purpose: "") }.buttonStyle(.borderedProminent) }
            ForEach(store.data.twins) { version in
                WorkspacePanel {
                    HStack { Text(version.name).font(.title3.weight(.semibold)); Spacer(); Text(version.enabled ? "Enabled" : "Paused").font(.caption); Button("Configure") { twin = version } }
                    Text(version.purpose).foregroundStyle(.secondary)
                    if let labels = version.suggestedSubjects, !labels.isEmpty {
                        Text("Suggested subjects: " + labels.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Audience: \(version.memberIDs.count) · Knowledge: \(version.sourceIDs.count) · \(version.verbosity.rawValue.capitalized) answers").font(.caption)
                    Text("\(timeLabel(version.startMinute))–\(timeLabel(version.endMinute)) · \(version.timeZone)").font(.caption).foregroundStyle(.secondary)
                    if let person = store.data.members.first(where: { version.memberIDs.contains($0.id) }) {
                        DisclosureGroup("Test as \(person.name)") {
                            WorkspaceQuestionBox(memberID: person.id, twinID: version.id, initialTopic: version.topics.sorted().first ?? "Engineering")
                        }
                    }
                }
            }
        } else if tab == "Channels" {
            WorkspaceChannels(slack: store.slack)
        } else if tab == "Agent access" {
            WorkspaceAgentAccess(gateway: store.gateway)
        } else {
            HStack {
                Picker("Person", selection: $personFilter) { Text("Everyone").tag(UUID?.none); ForEach(store.data.members) { Text($0.name).tag(Optional($0.id)) } }
                Picker("Topic", selection: $topicFilter) { Text("All topics").tag("All topics"); ForEach(Array(Set(store.data.consultations.map(\.topic))).sorted(), id: \.self) { Text($0).tag($0) } }
                Picker("Period", selection: $timeFilter) { ForEach(["All time", "Today", "Last 7 days", "Last 30 days"], id: \.self) { Text($0).tag($0) } }
            }
            let records = store.data.consultations.filter { (personFilter == nil || $0.memberID == personFilter) && (topicFilter == "All topics" || $0.topic == topicFilter) && $0.createdAt >= cutoff }
            WorkspacePanel {
                HStack(spacing: 32) {
                    metric("Questions", records.count)
                    metric("Answered", records.filter { $0.outcome == .answered }.count)
                    metric("Needs review", records.filter { $0.outcome == .needsReview }.count)
                    metric("Blocked", records.filter { $0.outcome == .denied || $0.outcome == .outsideHours }.count)
                }
                Text("Counts come from actual questions on this Mac, including your access tests. No sample activity is included.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(records.reversed())) { record in
                WorkspacePanel {
                    Text(record.question).font(.headline)
                    Text("\(store.data.members.first { $0.id == record.memberID }?.name ?? "You") · \(record.topic) · \(record.outcome.title)").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Owner record") { Text(record.answer).textSelection(.enabled) }
                    Text(record.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Color.clear.frame(height: 0).sheet(item: $member) { LocalWorkspaceMemberEditor(member: $0) }
            .sheet(item: $twin) { WorkspaceTwinEditor(twin: $0) }
    }
    var cutoff: Date {
        switch timeFilter {
        case "Today": return Calendar.current.startOfDay(for: Date())
        case "Last 7 days": return Date().addingTimeInterval(-7 * 86400)
        case "Last 30 days": return Date().addingTimeInterval(-30 * 86400)
        default: return .distantPast
        }
    }
    func metric(_ title: String, _ count: Int) -> some View { VStack(alignment: .leading, spacing: 4) { Text(String(count)).font(.system(size: 30, weight: .semibold, design: .rounded)); Text(title).font(.caption).foregroundStyle(.secondary) } }
}

private func timeLabel(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
private func topicSet(_ text: String) -> Set<String> { Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) }

struct LocalWorkspaceMemberEditor: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @Environment(\.dismiss) var dismiss
    @State var member: LocalWorkspaceMember
    @State private var topics = ""
    @State private var restrictSubjects = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Person & permissions").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name · required").font(.callout.weight(.medium))
                    TextField("Name", text: $member.name).labelsHidden().accessibilityLabel("Person name").accessibilityIdentifier("member-name")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Role").font(.callout.weight(.medium))
                    TextField("Role", text: $member.role).labelsHidden().accessibilityLabel("Role")
                }
                DisclosureGroup("Advanced subject restrictions") {
                    Toggle("Limit this person to specific subjects", isOn: $restrictSubjects)
                    if restrictSubjects { TextField("Subjects, separated by commas", text: $topics).accessibilityIdentifier("member-topics") }
                    Text("By default, access is limited by the knowledge you select below. Subject labels are not required.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Can ask this twin", isOn: $member.canAsk)
                    Toggle("Can read retrieved evidence", isOn: $member.canReadEvidence)
                    Text("Access changes take effect on the next request and on answers still being prepared.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 12) {
                Text("Permitted knowledge").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.data.documents) { doc in
                            Toggle(isOn: Binding(get: { member.sourceIDs.contains(doc.id) }, set: { if $0 { member.sourceIDs.insert(doc.id) } else { member.sourceIDs.remove(doc.id) } })) {
                                Text(doc.title + (doc.teamVisible ? "" : " · private")).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            }.disabled(!doc.teamVisible)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }.frame(height: 180)
            }
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                Button("Save access") {
                    member.topics = restrictSubjects ? topicSet(topics) : []
                    if store.update({ value in
                        if let i = value.members.firstIndex(where: { $0.id == member.id }) { value.members[i] = member } else { value.members.append(member) }
                        value.events.append(WorkspaceEvent(title: "Access updated", detail: member.name))
                    }) { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (restrictSubjects && topicSet(topics).isEmpty))
            }
        }.frame(width: 534, alignment: .leading).padding(28).onAppear { topics = member.topics.sorted().joined(separator: ", "); restrictSubjects = !member.topics.isEmpty }
    }
}

struct WorkspaceTwinEditor: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @Environment(\.dismiss) var dismiss
    @State var twin: WorkspaceTwin
    @State private var topics = ""
    @State private var restrictSubjects = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Build a version of you").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Form {
                        TextField("Name · required", text: $twin.name).accessibilityLabel("Twin name").accessibilityIdentifier("twin-name")
                        TextField("Purpose", text: $twin.purpose, axis: .vertical).accessibilityLabel("Twin purpose").accessibilityIdentifier("twin-purpose")
                        DisclosureGroup("Advanced subject restrictions") {
                            Toggle("Limit this twin to specific subjects", isOn: $restrictSubjects)
                            if restrictSubjects { TextField("Subjects, separated by commas", text: $topics).accessibilityIdentifier("twin-topics") }
                        }
                        Picker("Answer length", selection: $twin.verbosity) {
                            Text("Brief").tag(WorkspaceTwin.Verbosity.brief)
                            Text("Standard").tag(WorkspaceTwin.Verbosity.standard)
                        }
                        Picker("Skill", selection: $twin.skillID) {
                            Text("General questions").tag(UUID?.none)
                            ForEach(store.data.skills.filter { $0.trigger == .question }) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Toggle("Hold answers for my review", isOn: $twin.requiresOwnerReview)
                        Toggle("Enabled", isOn: $twin.enabled)
                    }
                    Text("Choose the people and knowledge below. The model can suggest subjects for organization; suggestions do not change access.").font(.caption).foregroundStyle(.secondary)
                    Button(store.working ? "Finding subjects…" : "Suggest subjects from selected knowledge") {
                        Task {
                            let docs = store.data.documents.filter { twin.sourceIDs.contains($0.id) }
                            if let labels = await store.suggestSubjects(docs) { twin.suggestedSubjects = labels }
                        }
                    }.disabled(store.working || twin.sourceIDs.isEmpty)
                    if let labels = twin.suggestedSubjects, !labels.isEmpty {
                        Text("Suggested subjects: " + labels.joined(separator: ", ")).font(.callout)
                        Button("Clear suggestions") { twin.suggestedSubjects = nil }
                    }
                    Text("Who can use this version? · required").font(.headline)
                    if twin.memberIDs.isEmpty { Text("Select at least one person below.").font(.caption).foregroundStyle(.secondary) }
                    if store.data.members.isEmpty { Text("Add a person in People & access first.").font(.caption) }
                    ForEach(store.data.members) { person in
                        Toggle(person.name, isOn: Binding(get: { twin.memberIDs.contains(person.id) }, set: { if $0 { twin.memberIDs.insert(person.id) } else { twin.memberIDs.remove(person.id) } }))
                    }
                    Text("Knowledge scope · required").font(.headline)
                    if twin.sourceIDs.isEmpty { Text("Select at least one shared source below.").font(.caption).foregroundStyle(.secondary) }
                    if !store.data.documents.contains(where: \.teamVisible) { Text("Make a source available for team scopes in Knowledge first.").font(.caption) }
                    ForEach(store.data.documents.filter(\.teamVisible)) { doc in
                        Toggle(doc.title, isOn: Binding(get: { twin.sourceIDs.contains(doc.id) }, set: { if $0 { twin.sourceIDs.insert(doc.id) } else { twin.sourceIDs.remove(doc.id) } }))
                    }
                    Text("Available hours").font(.headline)
                    HStack {
                        ForEach(1...7, id: \.self) { day in
                            Toggle(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][day - 1], isOn: Binding(get: { twin.weekdays.contains(day) }, set: { if $0 { twin.weekdays.insert(day) } else { twin.weekdays.remove(day) } })).toggleStyle(.button)
                        }
                    }
                    HStack {
                        Picker("From", selection: $twin.startMinute) { ForEach(0..<24, id: \.self) { Text(timeLabel($0 * 60)).tag($0 * 60) } }.accessibilityIdentifier("twin-start")
                        Picker("Until", selection: $twin.endMinute) { ForEach(0..<24, id: \.self) { Text(timeLabel($0 * 60)).tag($0 * 60) }; Text("23:59").tag(1439) }.accessibilityIdentifier("twin-end")
                    }
                    TextField("Time zone", text: $twin.timeZone).textFieldStyle(.roundedBorder)
                    Text("Access is the intersection of this version, the person’s permissions, and sources marked available to the team. Equal start and end times mean unavailable.").font(.caption).foregroundStyle(.secondary)
                }.padding(.trailing, 8)
            }.frame(maxHeight: 560)
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                Button("Save twin") {
                    twin.topics = restrictSubjects ? topicSet(topics) : []
                    guard TimeZone(identifier: twin.timeZone) != nil else { store.error = "Choose a valid time zone, such as America/New_York."; return }
                    if store.update({ value in
                        if let i = value.twins.firstIndex(where: { $0.id == twin.id }) { value.twins[i] = twin } else { value.twins.append(twin) }
                        value.events.append(WorkspaceEvent(title: "Twin configured", detail: twin.name))
                    }) {
                        let saved = twin
                        if store.data.runtime.lastVerifiedAt != nil && (saved.suggestedSubjects ?? []).isEmpty {
                            Task {
                                let docs = store.data.documents.filter { saved.sourceIDs.contains($0.id) }
                                if let labels = await store.suggestSubjects(docs) {
                                    store.update { value in
                                        if let index = value.twins.firstIndex(where: { $0.id == saved.id && $0.sourceIDs == saved.sourceIDs }),
                                           docs.allSatisfy({ value.documents.contains($0) }) { value.twins[index].suggestedSubjects = labels }
                                    }
                                }
                            }
                        }
                        dismiss()
                    }
                }.buttonStyle(.borderedProminent).disabled(twin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (restrictSubjects && topicSet(topics).isEmpty) || twin.memberIDs.isEmpty || twin.sourceIDs.isEmpty)
            }
        }.padding(28).frame(width: 640).onAppear { topics = twin.topics.sorted().joined(separator: ", "); restrictSubjects = !twin.topics.isEmpty }
    }
}

struct WorkspaceSkills: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @State private var editing: WorkspaceSkill?
    var body: some View {
        WorkspaceHeading(eyebrow: "Skills & schedules", title: "Give your judgment a job.", detail: "Create a reusable question skill, or prepare a recurring draft for your review while Bestmate is open.")
        Button("Create skill") { editing = WorkspaceSkill(name: "", instructions: "") }.buttonStyle(.borderedProminent)
        ForEach(store.data.skills) { skill in
            WorkspacePanel {
                HStack { Text(skill.name).font(.headline); Spacer(); Button("Edit") { editing = skill } }
                Text(skill.instructions).foregroundStyle(.secondary)
                Text(skill.trigger == .question ? "Available to attach to a twin" : "\(skill.trigger.rawValue.capitalized) at \(timeLabel(skill.minute)) · \(skill.timeZone) · \(skill.enabled ? "Enabled while app is open" : "Paused")").font(.caption)
                if let draft = skill.latestDraft { DisclosureGroup("Latest draft") { Text(draft).textSelection(.enabled) } }
                if skill.trigger != .question { Button("Run now") { Task { await store.runSkill(skill.id) } }.disabled(store.working) }
            }
        }
        Color.clear.frame(height: 0).sheet(item: $editing) { WorkspaceSkillEditor(skill: $0) }
    }
}

struct WorkspaceSkillEditor: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @Environment(\.dismiss) var dismiss
    @State var skill: WorkspaceSkill
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reusable skill").font(.title2.weight(.semibold))
            TextField("Name", text: $skill.name).accessibilityIdentifier("skill-name")
            Text("Describe the question or review this skill should carry out using the permitted material.").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $skill.instructions).frame(height: 150).accessibilityLabel("Skill instructions").accessibilityIdentifier("skill-instructions")
            Picker("Run", selection: $skill.trigger) { ForEach(WorkspaceSkill.Trigger.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            if skill.trigger != .question {
                Picker("At", selection: $skill.minute) { ForEach(0..<24, id: \.self) { Text(timeLabel($0 * 60)).tag($0 * 60) } }
                if skill.trigger == .weekly { Picker("Day", selection: $skill.weekday) { ForEach(1...7, id: \.self) { Text(["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][$0 - 1]).tag($0) } } }
                TextField("Time zone", text: $skill.timeZone)
                Toggle("Run while Bestmate is open", isOn: $skill.enabled)
                Text("Creates an owner-only draft from this workspace. It never sends a message or performs an external action. A missed run is prepared when the app next opens.").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save skill") {
                guard TimeZone(identifier: skill.timeZone) != nil else { store.error = "Choose a valid time zone."; return }
                if store.update({ value in if let i = value.skills.firstIndex(where: { $0.id == skill.id }) { value.skills[i] = skill } else { value.skills.append(skill) } }) { dismiss() }
            }.buttonStyle(.borderedProminent).disabled(skill.name.isEmpty || skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(28).frame(width: 580)
    }
}

struct WorkspaceOnboarding: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @State private var changingPurpose = false
    private var needsPurpose: Bool { store.data.purpose == nil || changingPurpose }
    private let steps = ["Purpose", "Environment", "Knowledge", "Judgment", "First twin", "Try access", "Connect", "Ready"]
    private var visualStep: Int { needsPurpose ? 0 : store.data.onboardingStep == 6 ? 6 : store.data.onboardingStep == 5 ? 7 : store.data.onboardingStep + 1 }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, name in
                        VStack(alignment: .leading, spacing: 8) { Capsule().fill(index <= visualStep ? WorkspaceTheme.accent : Color.secondary.opacity(0.15)).frame(height: 3); Text(name).font(.caption).foregroundStyle(index == visualStep ? .primary : .secondary) }.frame(maxWidth: .infinity)
                    }
                }
                if needsPurpose {
                    WorkspacePurposePicker { changingPurpose = false }
                } else {
                switch store.data.onboardingStep {
                case 0: WorkspaceSetup(onboarding: true)
                case 1: WorkspaceKnowledge()
                case 2: WorkspaceReview()
                case 3: WorkspaceTeam()
                case 4:
                    WorkspaceHeading(eyebrow: "Teammate preview", title: "See what someone else receives.", detail: "This is a real local question using the selected person’s permissions. Private or unassigned documents are excluded before retrieval.")
                    if let twin = store.data.twins.first, let member = store.data.members.first(where: { twin.memberIDs.contains($0.id) }) {
                        Text("As \(member.name), using \(twin.name)").font(.headline)
                        WorkspaceQuestionBox(memberID: member.id, twinID: twin.id, initialTopic: twin.topics.sorted().first ?? "Engineering")
                    } else { Text("Add a person to your first twin in the previous step.") }
                case 6:
                    WorkspaceHeading(eyebrow: "Connect your twin", title: "Choose where people can reach it.", detail: "Connect an agent on this Mac using a scoped credential. You can finish setup now and connect later from Team → Agent access.")
                    WorkspaceChannels(slack: store.slack)
                    WorkspaceAgentAccess(gateway: store.gateway)
                default:
                    WorkspaceHeading(eyebrow: "Your workspace is ready", title: "Keep the final say.", detail: "Your sources are local. Decisions are versioned. Each twin has an explicit audience and scope.")
                    WorkspacePanel {
                        Label("\(store.data.documents.count) local sources", systemImage: "doc.on.doc")
                        Label("\(store.data.judgments.filter { $0.status == .approved }.count) owner-approved decisions", systemImage: "checkmark.seal")
                        Label("\(store.data.twins.count) configured twins", systemImage: "person.2")
                        Text("The next step is your live workspace. You can change access and review decisions at any time.").foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack {
                    Button("Back") {
                        if store.data.onboardingStep == 0 { changingPurpose = true }
                        else { store.update { value in
                            value.onboardingStep = value.onboardingStep == 6 ? 4 : value.onboardingStep == 5 ? 6 : value.onboardingStep - 1
                        } }
                    }
                    Spacer()
                    if !canContinue { Text(requirement).font(.caption).foregroundStyle(.secondary) }
                    Button(store.data.onboardingStep == 5 ? "Open workspace →" : "Continue →") {
                        store.update { value in
                            if value.onboardingStep == 5 { value.onboardingComplete = true }
                            else { value.onboardingStep = value.onboardingStep == 4 ? 6 : value.onboardingStep == 6 ? 5 : value.onboardingStep + 1 }
                        }
                    }.buttonStyle(.borderedProminent).disabled(!canContinue)
                }
                }
            }.padding(36).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    var canContinue: Bool {
        switch store.data.onboardingStep {
        case 0: return store.data.runtime.lastVerifiedAt != nil
        case 1: return !store.data.documents.isEmpty
        case 2: return store.data.judgments.contains { $0.status == .approved }
        case 3: return store.data.twins.contains { !$0.memberIDs.isEmpty && !$0.sourceIDs.isEmpty }
        case 4: return store.data.consultations.contains { $0.memberID != nil && ($0.outcome == .answered || $0.outcome == .needsReview) }
        default: return true
        }
    }
    var requirement: String {
        switch store.data.onboardingStep {
        case 0: return "Verify the local runtime first."
        case 1: return "Add one source to begin."
        case 2: return "Review and approve your first decision."
        case 3: return "Configure a twin with a person and shared source."
        case 4: return "Complete a permitted test question."
        default: return ""
        }
    }
}
