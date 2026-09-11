import SwiftUI
import Network
import CryptoKit

struct WorkspaceWhatsAppRoute: Codable, Equatable, Identifiable {
    var id = UUID()
    var phone: String
    var memberID: UUID
    var twinID: UUID
    var topic: String
}

@MainActor
final class WorkspaceWhatsAppConnection: NSObject, ObservableObject, URLSessionTaskDelegate {
    @Published private(set) var message = "WhatsApp is disconnected."
    @Published private(set) var running = false
    private var listener: NWListener?
    private var generation = UUID()
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var seen = Set<String>()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    nonisolated static func verified(body: Data, signature: String, secret: String) -> Bool {
        guard signature.hasPrefix("sha256="), signature.count == 71 else { return false }
        let hex = Array(signature.dropFirst(7)); var bytes = [UInt8]()
        for i in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(hex[i...i+1]), radix: 16) else { return false }
            bytes.append(byte)
        }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: body, using: SymmetricKey(data: Data(secret.utf8)))
    }

    nonisolated static func incoming(_ payload: [String: Any], numberID: String) -> [[String: Any]] {
        guard payload["object"] as? String == "whatsapp_business_account" else { return [] }
        return (payload["entry"] as? [[String: Any]] ?? []).flatMap { entry in
            (entry["changes"] as? [[String: Any]] ?? []).flatMap { change -> [[String: Any]] in
                guard change["field"] as? String == "messages", let value = change["value"] as? [String: Any],
                      (value["metadata"] as? [String: Any])?["phone_number_id"] as? String == numberID else { return [] }
                return (value["messages"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            }
        }
    }

    func stop() {
        generation = UUID(); listener?.cancel(); listener = nil
        pending.values.forEach { $0.cancel() }; pending = [:]
        running = false; message = "WhatsApp is disconnected."
    }

    private static func respond(_ connection: NWConnection, status: Int, text: String = "OK") {
        let body = Data(text.utf8)
        let header = "HTTP/1.1 \(status) Response\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    func start(store: NativeWorkspaceStore, token: String, secret: String, verifyToken: String, numberID: String, version: String) {
        stop()
        guard !token.isEmpty, !secret.isEmpty, !verifyToken.isEmpty,
              numberID.range(of: "^[0-9]+$", options: .regularExpression) != nil,
              version.range(of: "^v[0-9]+\\.0$", options: .regularExpression) != nil else { message = "Enter the Meta credentials, business phone number ID, and Graph API version from your Meta app."; return }
        seen = []
        let current = generation
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 4393)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, current == self.generation else { return }
                    switch state {
                    case .ready: self.running = true; self.message = "Local receiver ready on port 4393. Configure your public HTTPS webhook in Meta to finish connecting."
                    case .failed: self.stop(); self.message = "Could not start WhatsApp receiver. Check whether port 4393 is in use."
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global(qos: .userInitiated))
                let timeout = DispatchWorkItem { connection.cancel() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
                WorkspaceHTTPRequest(connection: connection).read { request in
                    timeout.cancel()
                    Task { @MainActor in
                        guard let self, current == self.generation, let request else { Self.respond(connection, status: 400); return }
                        let parts = URLComponents(string: "http://localhost" + request.path)
                        guard parts?.path == "/whatsapp" else { Self.respond(connection, status: 404); return }
                        if request.method == "GET" {
                            let query = parts?.queryItems ?? []
                            let value = { (name: String) in query.first { $0.name == name }?.value }
                            guard value("hub.mode") == "subscribe", value("hub.verify_token") == verifyToken, let challenge = value("hub.challenge") else { Self.respond(connection, status: 403); return }
                            Self.respond(connection, status: 200, text: challenge); self.message = "Meta verified the webhook. Waiting for a mapped sender’s message."; return
                        }
                        guard request.method == "POST", Self.verified(body: request.body, signature: request.headers["x-hub-signature-256"] ?? "", secret: secret) else { Self.respond(connection, status: 403); return }
                        guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { Self.respond(connection, status: 400); return }
                        let messages = Self.incoming(payload, numberID: numberID)
                        guard self.pending.isEmpty, !store.working, messages.count <= 16 else { Self.respond(connection, status: 503); return }
                        Self.respond(connection, status: 200)
                        var previous: Task<Void, Never>?
                        for item in messages {
                            guard let id = item["id"] as? String, !self.seen.contains(id), self.seen.count < 10000,
                                  let sender = item["from"] as? String,
                                  let route = store.data.whatsAppRoutes?.first(where: { $0.phone == sender }),
                                  let question = (item["text"] as? [String: Any])?["body"] as? String,
                                  let timestamp = item["timestamp"] as? String, let sent = Double(timestamp),
                                  Date().timeIntervalSince1970 - sent < 23 * 3600, sent <= Date().timeIntervalSince1970 + 60 else { continue }
                            self.seen.insert(id)
                            let key = UUID()
                            let predecessor = previous
                            let work = Task {
                                if let predecessor { await predecessor.value }
                                defer { self.pending.removeValue(forKey: key) }
                                guard !Task.isCancelled, current == self.generation, (store.data.whatsAppRoutes ?? []).contains(route) else { return }
                                let memberBefore = store.data.members.first { $0.id == route.memberID }
                                let twinBefore = store.data.twins.first { $0.id == route.twinID }
                                let docsBefore = store.data.documents; let judgmentsBefore = store.data.judgments
                                let result: WorkspaceConsultation?
                                if question.lowercased().hasPrefix("status "), let receiptID = UUID(uuidString: String(question.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)) {
                                    result = store.consultationReceipt(receiptID, memberID: route.memberID, twinID: route.twinID)
                                } else { result = await store.consult(question: question, topic: route.topic, memberID: route.memberID, twinID: route.twinID, conversationID: "WorkspaceWhatsApp.swift|\(current)|\(route.id)|\(sender)") }
                                guard let result, !Task.isCancelled, current == self.generation, (store.data.whatsAppRoutes ?? []).contains(route),
                                      let member = store.data.members.first(where: { $0.id == route.memberID }), member == memberBefore,
                                      let twin = store.data.twins.first(where: { $0.id == route.twinID }), twin == twinBefore,
                                      store.data.documents == docsBefore,
                                      case .allowed = WorkspaceAccessPolicy.evaluate(member: member, twin: twin, documents: store.data.documents, topic: route.topic, at: Date()) else { return }
                                let checked: WorkspaceConsultation
                                if result.reviewID != nil {
                                    guard let receipt = store.consultationReceipt(result.id, memberID: route.memberID, twinID: route.twinID) else { return }
                                    checked = receipt
                                } else { guard store.data.judgments == judgmentsBefore else { return }; checked = result }
                                let answer = checked.outcome == .needsReview ? "Owner review is needed in Bestmate. After approval, send: status \(checked.id.uuidString)" : checked.answer
                                do {
                                    var req = URLRequest(url: URL(string: "https://graph.facebook.com/\(version)/\(numberID)/messages")!)
                                    req.httpMethod = "POST"; req.timeoutInterval = 15
                                    req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                                    req.httpBody = try JSONSerialization.data(withJSONObject: ["messaging_product": "whatsapp", "to": sender, "type": "text", "text": ["preview_url": false, "body": String(answer.prefix(3000)).replacingOccurrences(of: "\\[[a-zA-Z0-9_-]+\\]", with: "", options: .regularExpression)]])
                                    let (_, response) = try await self.session.data(for: req)
                                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WorkspaceStorageError.invalid("Meta rejected the reply.") }
                                    self.message = "Replied to the mapped sender on WhatsApp."
                                } catch { self.message = "WhatsApp delivery failed. Check the Meta token, phone setup, and API version. No automatic resend was attempted." }
                            }
                            self.pending[key] = work
                            previous = work
                        }
                    }
                }
            }
            self.listener = listener; listener.start(queue: .global(qos: .userInitiated))
        } catch { message = error.localizedDescription }
    }
}

struct WorkspaceWhatsAppSetup: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @ObservedObject var connection: WorkspaceWhatsAppConnection
    @State private var token = ""
    @State private var secret = ""
    @State private var verifyToken = ""
    @State private var numberID = ""
    @State private var version = ""
    @State private var phone = ""
    @State private var memberID: UUID?
    @State private var twinID: UUID?
    @State private var topic = ""
    private var subjects: [String] {
        WorkspaceAccessPolicy.sharedSubjects(member: store.data.members.first { $0.id == memberID }, twin: store.data.twins.first { $0.id == twinID })
    }
    private var selectedSubject: String { subjects.contains(topic) ? topic : subjects.first ?? "" }
    var body: some View {
        WorkspacePanel {
            Text("WhatsApp Business").font(.title3.weight(.semibold))
            Text("Connect a Meta business number for direct messages. Selected excerpts go to your configured model; messages and replies pass through WhatsApp.").fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Business number and webhook setup") {
                Text("Set up WhatsApp Cloud API in Meta. Forward a public HTTPS webhook URL to http://127.0.0.1:4393/whatsapp using your approved reverse proxy. Expose only this receiver, not the model or local agent ports. In Meta, enter that URL and your verification token, then subscribe to messages. Public hosting or a tunnel is not created automatically.").font(.callout)
                Link("Open Meta app settings", destination: URL(string: "https://developers.facebook.com/apps/")!)
            }
            TextField("Business phone number ID", text: $numberID)
            TextField("Graph API version from Meta · vNN.0", text: $version)
            SecureField("Meta access token", text: $token)
            SecureField("Meta app secret", text: $secret)
            SecureField("Webhook verification token · choose a secret", text: $verifyToken)
            Text("Credentials stay in memory for this session. This does not link a personal WhatsApp account.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Start WhatsApp receiver") { connection.start(store: store, token: token, secret: secret, verifyToken: verifyToken, numberID: numberID, version: version); token = ""; secret = ""; verifyToken = "" }.disabled(token.isEmpty || secret.isEmpty || verifyToken.isEmpty || numberID.isEmpty || version.isEmpty || (store.data.whatsAppRoutes ?? []).isEmpty)
                Button("Disconnect WhatsApp") { connection.stop() }
            }
            Text(connection.message).font(.caption).textSelection(.enabled)
            Divider()
            Text("Map a WhatsApp sender").font(.headline)
            TextField("Sender phone · country code and digits only", text: $phone)
            Picker("Bestmate person", selection: $memberID) { Text("Choose a person").tag(UUID?.none); ForEach(store.data.members) { Text($0.name).tag(Optional($0.id)) } }
            Picker("Twin", selection: $twinID) { Text("Choose a twin").tag(UUID?.none); ForEach(store.data.twins) { Text($0.name).tag(Optional($0.id)) } }
            Picker("Allowed subject", selection: Binding(get: { selectedSubject }, set: { topic = $0 })) {
                if subjects.isEmpty { Text("Choose a person and twin with a shared subject").tag("") }
                ForEach(subjects, id: \.self) { Text($0).tag($0) }
            }.disabled(subjects.isEmpty)
            if memberID != nil && twinID != nil && subjects.isEmpty {
                Text("The person must belong to this twin and share an allowed subject. Update People & access and Twins first.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Save WhatsApp mapping") {
                guard let memberID, let twinID, phone.range(of: "^[0-9]{7,15}$", options: .regularExpression) != nil,
                      let member = store.data.members.first(where: { $0.id == memberID }), let twin = store.data.twins.first(where: { $0.id == twinID }),
                      twin.memberIDs.contains(memberID), WorkspaceAccessPolicy.sharedSubjects(member: member, twin: twin).contains(selectedSubject) else { store.error = "Choose a permitted person/twin, a shared subject, and a sender phone with country code and digits only."; return }
                store.update { value in
                    var routes = value.whatsAppRoutes ?? []; routes.removeAll { $0.phone == phone }
                    routes.append(WorkspaceWhatsAppRoute(phone: phone, memberID: memberID, twinID: twinID, topic: selectedSubject)); value.whatsAppRoutes = routes
                }
            }.disabled(memberID == nil || twinID == nil || phone.isEmpty || selectedSubject.isEmpty)
            ForEach(store.data.whatsAppRoutes ?? []) { route in
                HStack { Text("\(route.phone) · \(route.topic)").font(.caption); Spacer(); Button("Remove sender") { store.update { $0.whatsAppRoutes?.removeAll { $0.id == route.id } } } }
            }
        }.onAppear { topic = store.data.purpose?.topic ?? "General" }
    }
}
