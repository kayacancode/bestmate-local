import SwiftUI

struct WorkspaceTelegramRoute: Codable, Equatable, Identifiable {
    var id = UUID()
    var chatID: String
    var senderID: String
    var memberID: UUID
    var twinID: UUID
    var topic: String
    var ownsAudience: Bool?
}

@MainActor
final class WorkspaceTelegramConnection: NSObject, ObservableObject, URLSessionTaskDelegate {
    @Published var message = "Telegram is disconnected."
    @Published private(set) var running = false
    @Published private(set) var observedChat = ""
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    nonisolated static func incoming(_ update: [String: Any], username: String, routes: [WorkspaceTelegramRoute]) -> (WorkspaceTelegramRoute, String, String)? {
        guard let msg = update["message"] as? [String: Any], msg["sender_chat"] == nil,
              let from = msg["from"] as? [String: Any], from["is_bot"] as? Bool == false,
              let sender = (from["id"] as? NSNumber)?.stringValue,
              let chat = msg["chat"] as? [String: Any], let chatID = (chat["id"] as? NSNumber)?.stringValue,
              let type = chat["type"] as? String, ["private", "group", "supergroup"].contains(type),
              var text = msg["text"] as? String,
              let route = routes.first(where: { $0.chatID == chatID && $0.senderID == sender }) ?? routes.first(where: { $0.chatID == chatID && $0.senderID.isEmpty }) else { return nil }
        if type != "private" {
            let prefix = "/ask@" + username
            guard text.lowercased().hasPrefix(prefix.lowercased() + " ") else { return nil }
            text = String(text.dropFirst(prefix.count))
        } else if text.hasPrefix("/ask ") { text = String(text.dropFirst(5)) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("/"), text.count <= 2000 else { return nil }
        return (route, sender, text)
    }

    private func api(_ method: String, token: String, body: [String: Any] = [:]) async throws -> Any {
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/\(method)")!)
        request.httpMethod = "POST"; request.timeoutInterval = 40
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Telegram tokens are part of request URLs. Never surface transport errors or provider bodies.
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["ok"] as? Bool == true,
                  let value = result["result"] else { throw WorkspaceStorageError.invalid("Telegram request failed.") }
            return value
        } catch { throw WorkspaceStorageError.invalid("Telegram could not complete \(method). Check the bot token, connection, and whether another app is using this bot.") }
    }

    func stop() { generation = UUID(); task?.cancel(); task = nil; running = false; message = "Telegram is disconnected." }

    func start(store: NativeWorkspaceStore, token: String) {
        stop()
        guard token.range(of: "^[0-9]+:[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { message = "Enter the bot token from BotFather."; return }
        let current = generation
        let started = Date().timeIntervalSince1970
        message = "Connecting to Telegram…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let identity = try await api("getMe", token: token) as? [String: Any], let username = identity["username"] as? String else { return }
                guard let webhook = try await api("getWebhookInfo", token: token) as? [String: Any], (webhook["url"] as? String) == "" else {
                    throw WorkspaceStorageError.invalid("This bot already uses a webhook, possibly in legacy Bestmate. Use a separate BotFather bot for this local connection. The existing webhook was not changed.")
                }
                guard !Task.isCancelled, current == generation else { return }
                running = true; message = "Listening as @\(username). In a mapped group use /ask@\(username) followed by your question. Replies arrive privately."
                var offset: Int64 = 0
                while !Task.isCancelled && current == generation {
                    let updates = try await api("getUpdates", token: token, body: ["offset": offset, "timeout": 25, "limit": 1, "allowed_updates": ["message"]]) as? [[String: Any]] ?? []
                    for update in updates {
                        guard !Task.isCancelled, current == generation, let id = (update["update_id"] as? NSNumber)?.int64Value else { return }
                        offset = id + 1
                        guard let msg = update["message"] as? [String: Any], let date = (msg["date"] as? NSNumber)?.doubleValue,
                              date >= started else { continue }
                        if let chat = msg["chat"] as? [String: Any], let chatID = (chat["id"] as? NSNumber)?.stringValue {
                            observedChat = "Last received chat ID: " + chatID
                        }
                        guard let (route, sender, question) = Self.incoming(update, username: username, routes: store.data.telegramRoutes ?? []) else { continue }
                        while store.working && !Task.isCancelled { try await Task.sleep(nanoseconds: 500_000_000) }
                        guard !Task.isCancelled, current == generation, (store.data.telegramRoutes ?? []).contains(route) else { return }
                        guard let member = store.data.members.first(where: { $0.id == route.memberID }),
                              let twin = store.data.twins.first(where: { $0.id == route.twinID }) else { continue }
                        let documents = store.data.documents
                        let judgments = store.data.judgments
                        message = "Preparing a private Telegram reply…"
                        let result: WorkspaceConsultation?
                        if question.lowercased().hasPrefix("status "), let receipt = UUID(uuidString: String(question.dropFirst(7))) {
                            result = store.consultationReceipt(receipt, memberID: route.memberID, twinID: route.twinID)
                        } else {
                            result = await store.consult(question: question, topic: route.topic, memberID: route.memberID, twinID: route.twinID, conversationID: "WorkspaceTelegram.swift|\(current)|\(route.id)|\(sender)")
                        }
                        guard !Task.isCancelled, current == generation else { return }
                        guard (store.data.telegramRoutes ?? []).contains(route),
                              store.data.members.first(where: { $0.id == route.memberID }) == member,
                              store.data.twins.first(where: { $0.id == route.twinID }) == twin,
                              store.data.documents == documents,
                              case .allowed = WorkspaceAccessPolicy.evaluate(member: member, twin: twin, documents: documents, topic: route.topic, at: Date()), let result else {
                            message = "No reply sent: access changed or the request could not be answered."; continue
                        }
                        let checked: WorkspaceConsultation
                        if result.reviewID != nil {
                            guard let receipt = store.consultationReceipt(result.id, memberID: route.memberID, twinID: route.twinID) else { continue }
                            checked = receipt
                        } else { guard judgments == store.data.judgments else { continue }; checked = result }
                        let reply = checked.outcome == .needsReview ? "This answer needs the owner's review in Bestmate. Once approved, ask in the same chat: status \(checked.id.uuidString)" : checked.answer
                        do {
                            _ = try await api("sendMessage", token: token, body: ["chat_id": sender, "text": String(reply.prefix(3000)), "link_preview_options": ["is_disabled": true]])
                            message = "Replied privately in Telegram. Listening for the next question."
                        } catch { message = "The answer is saved in Bestmate, but Telegram delivery failed. The sender must open the bot and tap Start first. No automatic resend was attempted." }
                    }
                }
            } catch {
                guard !Task.isCancelled, current == generation else { return }
                running = false; message = error.localizedDescription + " Reconnect to try again."
            }
        }
    }
}

struct WorkspaceTelegramSetup: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @ObservedObject var connection: WorkspaceTelegramConnection
    @State private var token = ""
    @State private var chat = ""
    @State private var sender = ""
    @State private var twinID: UUID?
    @State private var topic = "General"
    private var topics: [String] { let values = store.data.twins.first { $0.id == twinID }?.topics ?? []; return values.isEmpty ? ["General"] : values.sorted() }
    private var subject: String { topics.contains(topic) ? topic : topics.first ?? "General" }
    var body: some View {
        WorkspacePanel {
            Text("Telegram").font(.title3.weight(.semibold))
            Text("Connect a bot to a group or private chat. Answers go privately to the sender. Everyone who will ask must open the bot and tap Start first. Retrieval stays on this Mac. Selected excerpts go to your configured model; messages travel through Telegram.")
            DisclosureGroup("Set up your Telegram bot") {
                Text("Create a dedicated bot with BotFather and paste its token below. Add it to your group. In groups, ask with /ask@your_bot followed by your question. Private chats accept plain questions. Use a dedicated bot if your legacy integration already uses a webhook.").font(.callout)
                Link("Open BotFather", destination: URL(string: "https://t.me/BotFather")!)
            }
            Text("Chat ID · required").font(.callout.weight(.medium))
            TextField("Group ID (negative number) or private chat ID", text: $chat).accessibilityIdentifier("telegram-chat-id")
            Text("To find the ID, connect below and send /start to the bot privately, or /ask@your_bot in the group. The received chat ID appears here.").font(.caption).foregroundStyle(.secondary)
            if !connection.observedChat.isEmpty { Text(connection.observedChat).font(.caption).textSelection(.enabled) }
            Text("Sender ID · optional").font(.callout.weight(.medium))
            TextField("Leave empty for anyone in this chat", text: $sender).accessibilityIdentifier("telegram-sender-id")
            Picker("Twin · required", selection: $twinID) { Text("Choose a twin").tag(UUID?.none); ForEach(store.data.twins) { Text($0.name).tag(Optional($0.id)) } }.accessibilityIdentifier("telegram-route-twin")
            if topics != ["General"] { Picker("Allowed subject", selection: Binding(get: { subject }, set: { topic = $0 })) { ForEach(topics, id: \.self) { Text($0).tag($0) } } }
            Text("Saving creates a Telegram audience in People & access with this twin’s currently shared sources. An optional sender ID limits who can use that mapping.").font(.caption).foregroundStyle(.secondary)
            Button("Save Telegram mapping") { if let twinID { _ = store.saveTelegramMapping(channel: chat, sender: sender, memberID: nil, twinID: twinID, subject: subject) } }.disabled(chat.isEmpty || twinID == nil)
            ForEach(store.data.telegramRoutes ?? []) { route in
                HStack {
                    Text("\(route.chatID) · \(route.senderID.isEmpty ? "Anyone in this chat" : route.senderID)").font(.caption)
                    Spacer()
                    Button("Remove") { store.update { $0.telegramRoutes?.removeAll { $0.id == route.id } } }
                }
            }
            Divider()
            Text("Bot token · from BotFather").font(.callout.weight(.medium))
            SecureField("Bot token", text: $token).accessibilityIdentifier("telegram-bot-token")
            Text("The token stays in memory for this connection. Closing Bestmate disconnects the bot. Only messages sent after connecting are processed; earlier messages are skipped.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Connect Telegram") { connection.start(store: store, token: token.trimmingCharacters(in: .whitespacesAndNewlines)) }.disabled(token.isEmpty || connection.running)
                Button("Disconnect Telegram") { connection.stop() }
            }
            Text(connection.message).font(.caption).textSelection(.enabled)
        }.onChange(of: connection.running) { if $0 { token = "" } }
    }
}
