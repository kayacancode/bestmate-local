import SwiftUI

enum WorkspacePurpose: String, Codable, CaseIterable, Identifiable {
    case programming, teammates
    // Preserve existing saved purpose choices when replacing the proposal-review option.
    case leadership = "proposals"
    case writing, consulting
    var id: String { rawValue }
    var title: String {
        switch self {
        case .programming: return "Help a junior developer"
        case .teammates: return "Answer teammates’ questions"
        case .leadership: return "Help my team make decisions like me"
        case .writing: return "Write in my voice"
        case .consulting: return "Advise clients like me"
        }
    }
    var detail: String {
        switch self {
        case .programming: return "Share how you reason about code, tradeoffs, and safe changes."
        case .teammates: return "Make your project context and recurring decisions easier to access."
        case .leadership: return "For CEOs: share your priorities, tradeoffs, and the decisions employees can own."
        case .writing: return "Share your style and the editorial choices behind it."
        case .consulting: return "Share how you diagnose client problems, recommend next steps, and set scope."
        }
    }
    var examples: [String] {
        switch self {
        case .programming: return ["A code review explaining why you requested a change", "An engineering guideline with exceptions", "A design decision with alternatives you ruled out"]
        case .teammates: return ["Meeting notes that changed a project’s next step", "A recurring question and your answer", "A project brief with decisions and owners"]
        case .leadership: return ["Company priorities and the principles behind them", "A decision memo explaining a tradeoff you made", "Examples of decisions employees can own and when to escalate"]
        case .writing: return ["An article you wrote", "A draft with your edits and reasoning", "An email that sounds like you"]
        case .consulting: return ["Discovery notes that changed your understanding of a client’s problem", "A client recommendation with alternatives and your reasoning", "A scope decision explaining what you included, excluded, or escalated"]
        }
    }
    var topic: String {
        switch self { case .programming: return "Engineering"; case .teammates: return "Project decisions"; case .leadership: return "Leadership decisions"; case .writing: return "Writing"; case .consulting: return "Client advisory" }
    }
    var question: String {
        switch self {
        case .programming: return "When would I ask a developer to pause and get a review before making a change?"
        case .teammates: return "Which project decisions should a teammate bring back to me?"
        case .leadership: return "Which decisions should employees make themselves, and which should come back to me?"
        case .writing: return "What would I change in a draft to make it sound more like me?"
        case .consulting: return "When would I recommend more discovery before proposing a solution to a client?"
        }
    }
    var searchTerms: [String] {
        switch self {
        case .programming: return ["code review", "tradeoff", "design decision", "because", "retry"]
        case .teammates: return ["decision", "owner", "next steps", "project", "escalate"]
        case .leadership: return ["priorities", "principles", "decision", "budget", "escalate"]
        case .writing: return ["draft", "editorial", "feedback", "rewrite", "because"]
        case .consulting: return ["discovery", "client", "recommendation", "scope", "tradeoff"]
        }
    }
    var sourceQuestion: String {
        switch self {
        case .programming: return "When does the source recommend pausing a code change for review, and why?"
        case .teammates: return "Which project decisions require the owner's review, and why?"
        case .leadership: return "What reasons does the author give for their decision?"
        case .writing: return "What writing or editing choices does the author explain, and why?"
        case .consulting: return "What reasons are given for the recommendation to the client?"
        }
    }
    var sample: String {
        switch self {
        case .consulting: return "Client recommendation: The client asked us to replace their reporting platform. Discovery interviews showed that inconsistent metric definitions were causing most of the confusion. I recommended agreeing on definitions and testing one reporting workflow before buying a new platform. Platform selection stays outside this phase; if the pilot still exposes a tooling gap, we will agree a separate scope with the sponsor."
        case .programming: return "Review comment: Please pause before retrying this migration. It writes partial output, so a retry could duplicate records. Check repeatability with the service owner first. I’m comfortable with automatic retries only for operations we have verified are idempotent."
        case .teammates: return "Project decision: Keep the pilot limited to one team this month. A teammate can adjust meeting times, but changes to the pilot audience or data access need my review. We chose a narrow pilot because we still need evidence that the permissions are correct."
        case .leadership: return "CEO decision note: This quarter, retaining our existing customers comes before entering new markets. Team leads can run reversible experiments within their agreed budgets without waiting for me. Bring back decisions that change company priorities, create a long-term commitment, or affect another team’s budget. When speed and certainty conflict, I prefer a small test with a named owner and a clear measure of success. Explain the tradeoff, not just the recommendation."
        case .writing: return "Editorial note: Replace the opening slogan with the actual finding. Use a concrete example before introducing the broader claim. Keep uncertainty visible: if we only tested one team, say so. I prefer short, direct sentences over confident claims without evidence."
        }
    }
}

struct WorkspacePurposePicker: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    var onContinue: () -> Void = {}
    @State private var selected: WorkspacePurpose?
    @State private var sample: WorkspacePurpose?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            WorkspaceHeading(eyebrow: "Start with a purpose", title: "What should your twin help with?", detail: "Choose a starting point. We’ll help you find material that shows how you think. You can change this later.")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(WorkspacePurpose.allCases) { purpose in
                    Button { selected = purpose } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(purpose.title).font(.custom("AvenirNext-DemiBold", size: 18))
                                Spacer()
                                Image(systemName: selected == purpose ? "checkmark.circle.fill" : "circle")
                            }
                            Text(purpose.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(20).frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
                            .background(WorkspaceTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected == purpose ? WorkspaceTheme.accent : WorkspaceTheme.line, lineWidth: selected == purpose ? 2 : 1))
                    }.buttonStyle(.plain).accessibilityIdentifier("purpose-" + purpose.rawValue)
                        .accessibilityAddTraits(selected == purpose ? .isSelected : [])
                }
            }
            if let selected {
                Text("A useful first source").font(.headline)
                Text(selected.examples[0]).foregroundStyle(.secondary)
                HStack {
                    Button("Preview an example workspace") { sample = selected }
                    Spacer()
                    Button("Use this purpose →") {
                        if store.update({ $0.purpose = selected }) { onContinue() }
                    }.buttonStyle(.borderedProminent)
                }
            }
        }.onAppear { selected = store.data.purpose }
            .sheet(item: $sample) { WorkspaceExample(purpose: $0) }
    }
}

struct WorkspaceExample: View {
    let purpose: WorkspacePurpose
    @Environment(\.dismiss) var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WorkspaceHeading(eyebrow: "Fictional example workspace", title: purpose.title, detail: "A preview of the flow. This example is not imported into your knowledge or used to learn your judgment.")
                WorkspacePanel { Text("1 · Add material").font(.headline); Text(purpose.sample) }
                WorkspacePanel { Text("2 · Try a question").font(.headline); Text(purpose.question) }
                WorkspacePanel {
                    Text("3 · Shape the answer").font(.headline)
                    Text("Review the evidence, correct the answer, and explain when your decision applies. Your explanation is what turns a source into useful judgment.")
                }
                Button("Use my own material") { dismiss() }.buttonStyle(.borderedProminent)
            }.padding(28)
        }.frame(width: 740, height: 620).background(WorkspaceTheme.background)
    }
}

struct WorkspaceSourceGuidance: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @State private var choosing = false
    @State private var sample: WorkspacePurpose?
    @State private var suggestion: WorkspaceSourceSuggestion?
    var body: some View {
        WorkspacePanel {
            if let purpose = store.data.purpose {
                HStack { Text("Good sources for your twin").font(.headline); Spacer(); Button("Change purpose") { choosing = true } }
                Text(purpose.title).font(.custom("AvenirNext-Medium", size: 20))
                ForEach(purpose.examples, id: \.self) { Text("• " + $0) }
                Text("Start with one or two sources. Material that explains a choice, correction, or exception helps us understand more than the finished result alone.").foregroundStyle(.secondary)
                HStack {
                    Button("See an example") { sample = purpose }
                    if !store.data.documents.isEmpty {
                        Button("Find useful material locally") {
                            let documents = store.data.documents
                            Task {
                                let result = await store.suggestSources(documents, for: purpose)
                                if store.data.documents == documents && store.data.purpose == purpose { suggestion = result }
                            }
                        }.disabled(store.working)
                    }
                }
                if let suggestion {
                    Divider()
                    Text("Suggested starting material · local model").font(.headline)
                    Text(suggestion.explanation).textSelection(.enabled)
                    ForEach(suggestion.sources) { Text($0.title).font(.callout.weight(.medium)) }
                    Text("These are suggestions based on your current sources, not approved judgments.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Not sure what to add?").font(.headline)
                Text("Choose what your twin should help with, then see concrete examples of useful sources.").foregroundStyle(.secondary)
                Button("Choose a purpose") { choosing = true }.buttonStyle(.borderedProminent)
            }
        }.sheet(isPresented: $choosing) {
            ScrollView { WorkspacePurposePicker { choosing = false; suggestion = nil }.padding(28) }.frame(width: 820, height: 650)
        }.sheet(item: $sample) { WorkspaceExample(purpose: $0) }
            .onChange(of: store.data.documents) { _ in suggestion = nil }
            .onChange(of: store.data.purpose) { _ in suggestion = nil }
    }
}

struct WorkspaceSourceSuggestion {
    let explanation: String
    let sources: [WorkspaceDocument]
}
