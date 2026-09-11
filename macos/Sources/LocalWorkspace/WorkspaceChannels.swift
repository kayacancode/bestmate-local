import SwiftUI

struct WorkspaceSlackRoute: Codable, Equatable, Identifiable {
    var id = UUID()
    var channelID: String
    var slackUserID: String
    var memberID: UUID
    var twinID: UUID
    var topic: String
    var ownsAudience: Bool?
}

/// An explicitly started Slack listener. Only exact channel/sender mappings can ask.
@MainActor
final class WorkspaceSlackConnection: NSObject, ObservableObject, URLSessionTaskDelegate {
    @Published var message = "Slack is disconnected."
    @Published private(set) var running = false
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var seen = Set<String>()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    nonisolated static func route(_ event: [String: Any], routes: [WorkspaceSlackRoute]) -> WorkspaceSlackRoute? {
        guard event["type"] as? String == "app_mention", event["bot_id"] == nil,
              event["subtype"] == nil, let user = event["user"] as? String,
              let channel = event["channel"] as? String else { return nil }
        return routes.first { $0.channelID == channel && $0.slackUserID == user }
            ?? routes.first { $0.channelID == channel && $0.slackUserID.isEmpty }
    }

    private func api(_ method: String, token: String, body: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://slack.com/api/" + method)!)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["ok"] as? Bool == true else {
            throw WorkspaceStorageError.invalid("Slack could not complete \(method). Check the app tokens, scopes, and channel membership.")
        }
        return result
    }

    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        requests.values.forEach { $0.cancel() }; requests = [:]
        running = false; message = "Slack is disconnected."
    }

    func start(store: NativeWorkspaceStore, botToken: String, appToken: String) {
        stop()
        guard botToken.hasPrefix("xoxb-"), appToken.hasPrefix("xapp-") else { message = "Enter a bot token (xoxb-) and Socket Mode app token (xapp-)."; return }
        seen = []
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let identity = try await api("auth.test", token: botToken)
                guard let teamID = identity["team_id"] as? String, let botID = identity["user_id"] as? String else { throw WorkspaceStorageError.invalid("Slack did not identify this bot.") }
                while !Task.isCancelled && current == generation {
                    message = "Connecting to Slack…"
                    let opened = try await api("apps.connections.open", token: appToken)
                    guard let value = opened["url"] as? String, let url = URL(string: value), url.scheme == "wss",
                          let host = url.host, host.hasSuffix(".slack.com") else { throw WorkspaceStorageError.invalid("Slack returned an invalid connection address.") }
                    let ws = session.webSocketTask(with: url); socket = ws; ws.resume()
                    var reconnect = false
                    while !Task.isCancelled && !reconnect && current == generation {
                        let frame = try await ws.receive()
                        let bytes: Data
                        switch frame { case .data(let data): bytes = data; case .string(let text): bytes = Data(text.utf8); @unknown default: continue }
                        guard let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { continue }
                        if envelope["type"] as? String == "hello" { running = true; message = "Listening for mapped mentions · replies go to the sender’s Slack DM."; continue }
                        if envelope["type"] as? String == "disconnect" { reconnect = true; continue }
                        if let id = envelope["envelope_id"] as? String {
                            let ack = try JSONSerialization.data(withJSONObject: ["envelope_id": id])
                            try await ws.send(.data(ack))
                        }
                        guard let payload = envelope["payload"] as? [String: Any], payload["team_id"] as? String == teamID,
                              let eventID = payload["event_id"] as? String, !seen.contains(eventID),
                              let event = payload["event"] as? [String: Any],
                              let route = Self.route(event, routes: store.data.slackRoutes ?? []),
                              let sender = event["user"] as? String,
                              let text = event["text"] as? String else { continue }
                        // Bound replay memory; no retry is sent automatically after a delivery error.
                        if seen.count >= 10000 { message = "Reconnect Slack to reset its event cache."; stop(); return }
                        seen.insert(eventID)
                        guard !store.working, requests.isEmpty else { message = "A mention arrived while the twin was busy. Ask again once the current question finishes."; continue }
                        let question = text.replacingOccurrences(of: "<@\(botID)>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let requestID = UUID()
                        requests[requestID] = Task {
                            defer { self.requests.removeValue(forKey: requestID) }
                            let originalMember = store.data.members.first { $0.id == route.memberID }
                            let originalTwin = store.data.twins.first { $0.id == route.twinID }
                            let originalDocuments = store.data.documents
                            let originalJudgments = store.data.judgments
                            let result: WorkspaceConsultation?
                            if question.lowercased().hasPrefix("status "), let id = UUID(uuidString: String(question.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)) {
                                result = store.consultationReceipt(id, memberID: route.memberID, twinID: route.twinID)
                            } else {
                                result = await store.consult(question: question, topic: route.topic, memberID: route.memberID, twinID: route.twinID, conversationID: "WorkspaceChannels.swift|\(current)|\(route.id)|\(sender)")
                            }
                            guard !Task.isCancelled, self.generation == current, (store.data.slackRoutes ?? []).contains(route), let result else { return }
                            do {
                                let dm = try await self.api("conversations.open", token: botToken, body: ["users": sender])
                                guard let channel = (dm["channel"] as? [String: Any])?["id"] as? String,
                                      !Task.isCancelled, self.generation == current, (store.data.slackRoutes ?? []).contains(route),
                                      let member = store.data.members.first(where: { $0.id == route.memberID }), member == originalMember,
                                      let twin = store.data.twins.first(where: { $0.id == route.twinID }), twin == originalTwin,
                                      store.data.documents == originalDocuments,
                                      case .allowed = WorkspaceAccessPolicy.evaluate(member: member, twin: twin, documents: store.data.documents, topic: route.topic, at: Date()) else { return }
                                let checked: WorkspaceConsultation
                                if result.reviewID != nil {
                                    guard let receipt = store.consultationReceipt(result.id, memberID: route.memberID, twinID: route.twinID) else { return }
                                    checked = receipt
                                } else {
                                    guard store.data.judgments == originalJudgments else { return }
                                    checked = result
                                }
                                let reply = checked.outcome == .needsReview ? "This answer needs the owner's review in Bestmate. Once approved, mention the bot in the mapped channel with: status \(checked.id.uuidString)" : checked.answer
                                let answer = String(reply.prefix(2500)).replacingOccurrences(of: "\\[[a-zA-Z0-9_-]+\\]", with: "", options: .regularExpression)
                                _ = try await self.api("chat.postMessage", token: botToken, body: ["channel": channel, "text": "Bestmate replied to your question.", "blocks": [["type": "section", "text": ["type": "plain_text", "text": answer]]], "unfurl_links": false, "unfurl_media": false])
                                self.message = "Replied privately in Slack. Owner reviews are in Bestmate → Review."
                            } catch { self.message = "The answer is saved in Bestmate, but Slack delivery failed. No automatic resend was attempted." }
                        }
                    }
                    ws.cancel(with: .goingAway, reason: nil)
                }
            } catch {
                if !Task.isCancelled && current == generation {
                    let detail = error.localizedDescription
                    stop(); message = detail + " Reconnect to try again."
                }
            }
        }
    }
}

struct WorkspaceChannels: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @ObservedObject var slack: WorkspaceSlackConnection
    @State private var botToken = ""
    @State private var appToken = ""
    @State private var channelID = ""
    @State private var userID = ""
    @State private var memberID: UUID?
    @State private var twinID: UUID?
    @State private var topic = ""
    private var subjects: [String] {
        guard let twin = store.data.twins.first(where: { $0.id == twinID }) else { return [] }
        if userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memberID == nil { return twin.topics.isEmpty ? ["General"] : twin.topics.sorted() }
        return WorkspaceAccessPolicy.sharedSubjects(member: store.data.members.first { $0.id == memberID }, twin: twin)
    }
    private var selectedSubject: String { subjects.contains(topic) ? topic : subjects.first ?? "" }
    var body: some View {
        WorkspacePanel {
            Text("Slack").font(.title3.weight(.semibold))
            Text("Mention your bot in a mapped channel. It replies privately to the sender, using the channel audience or their individual permissions. Messages and replies travel through Slack; retrieval stays on this Mac and selected excerpts go to your configured model.").fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Set up your Slack app") {
                Text("Create a Slack app, enable Socket Mode, and subscribe to app_mention. Add bot scopes app_mentions:read, chat:write, and im:write. Install it, invite the bot to your channel, and create an app token with connections:write.").font(.callout)
                Link("Open Slack app settings", destination: URL(string: "https://api.slack.com/apps")!)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Bot token · starts with xoxb-").font(.callout.weight(.medium))
                SecureField("Bot token", text: $botToken).accessibilityIdentifier("slack-bot-token")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Socket Mode app token · starts with xapp-").font(.callout.weight(.medium))
                SecureField("App token", text: $appToken).accessibilityIdentifier("slack-app-token")
            }
            Text("Tokens are used for this connection only. Closing the app disconnects Slack.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Connect Slack") {
                    slack.start(store: store, botToken: botToken.trimmingCharacters(in: .whitespacesAndNewlines), appToken: appToken.trimmingCharacters(in: .whitespacesAndNewlines))
                }.disabled(botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Disconnect") { slack.stop() }
            }
            if (store.data.slackRoutes ?? []).isEmpty {
                Text("You can connect now. Then add a channel and person below to enable replies. Until then, no questions are answered.").font(.callout).foregroundStyle(.secondary)
            }
            Text(slack.message).font(.caption).textSelection(.enabled)
        }
        WorkspacePanel {
            Text("Choose a Slack channel").font(.headline)
            Text("Anyone in this channel can mention the twin. Add a member ID only if you want to limit this mapping to one Slack user. A channel audience in People & access holds the selected twin’s shared-source permissions.").font(.caption)
            TextField("Slack channel ID · required · C…", text: $channelID).accessibilityIdentifier("slack-channel-id")
            TextField("Slack member ID · optional · U…", text: $userID).accessibilityIdentifier("slack-member-id")
            if !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Picker("Person permissions · optional", selection: $memberID) { Text("Use channel audience permissions").tag(UUID?.none); ForEach(store.data.members) { Text($0.name).tag(Optional($0.id)) } }
            }
            Picker("Twin", selection: $twinID) { Text("Choose a twin").tag(UUID?.none); ForEach(store.data.twins) { Text($0.name).tag(Optional($0.id)) } }.accessibilityIdentifier("slack-route-twin")
            Picker("Allowed subject", selection: Binding(get: { selectedSubject }, set: { topic = $0 })) {
                if subjects.isEmpty { Text("Choose a person and twin with a shared subject").tag("") }
                ForEach(subjects, id: \.self) { Text($0).tag($0) }
            }.disabled(subjects.isEmpty)
            if memberID != nil && twinID != nil && subjects.isEmpty {
                Text("The person must belong to this twin and share an allowed subject. Update People & access and Twins first.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Save mapping") {
                guard let twinID else { return }
                _ = store.saveSlackMapping(channel: channelID, sender: userID, memberID: userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : memberID, twinID: twinID, subject: selectedSubject)
            }.disabled(twinID == nil || channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedSubject.isEmpty)
            ForEach(store.data.slackRoutes ?? []) { route in
                HStack {
                    Text("\(route.channelID) · \(route.slackUserID.isEmpty ? "Anyone in this channel" : route.slackUserID) · \(route.topic)").font(.caption)
                    Spacer()
                    Button("Remove") { store.update { $0.slackRoutes?.removeAll { $0.id == route.id } } }
                }
            }
        }.onAppear { topic = store.data.purpose?.topic ?? "General" }
        .onChange(of: slack.running) { connected in if connected { botToken = ""; appToken = "" } }
        WorkspaceTelegramSetup(connection: store.telegram)
        WorkspaceWhatsAppSetup(connection: store.whatsApp)
    }
}
