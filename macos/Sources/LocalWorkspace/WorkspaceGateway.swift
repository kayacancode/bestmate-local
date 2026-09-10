import Foundation
import Network
import CryptoKit
import Security

/// Explicitly started local integration endpoint. Credentials bind an agent to one person/twin.
/// Raw credentials are shown once; only SHA-256 hashes are persisted.
@MainActor
final class WorkspaceGateway: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var message = "Local agent access is stopped."
    private var listener: NWListener?
    private weak var store: NativeWorkspaceStore?
    private var generation = UUID()
    static let port: UInt16 = 4392

    static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WorkspaceStorageError.invalid("A secure credential could not be generated.")
        }
        return "bm_local_" + Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    func start(store: NativeWorkspaceStore) throws {
        guard listener == nil else { return }
        self.store = store
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.running = true; self.message = "Listening on http://127.0.0.1:\(Self.port)/v1/ask"
                case .failed(let error): self.message = error.localizedDescription; self.stop()
                case .cancelled: self.running = false
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            let timeout = DispatchWorkItem { connection.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            let reader = WorkspaceHTTPRequest(connection: connection)
            reader.read { request in
                timeout.cancel()
                Task { @MainActor [weak self] in
                    guard let self else { connection.cancel(); return }
                    await self.handle(request, connection: connection)
                }
            }
        }
        self.listener = listener
        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() { generation = UUID(); listener?.cancel(); listener = nil; running = false; message = "Local agent access is stopped." }

    private func handle(_ request: WorkspaceHTTPRequest.Value?, connection: NWConnection) async {
        let requestGeneration = generation
        guard let store, let request, request.method == "POST", ["/v1/ask", "/v1/receipt"].contains(request.path),
              request.headers["host"] == "127.0.0.1:\(Self.port)", request.headers["origin"] == nil,
              let authorization = request.headers["authorization"], authorization.hasPrefix("Bearer "),
              let credential = store.data.credentials?.first(where: { $0.tokenHash == Self.hash(String(authorization.dropFirst(7))) }) else {
            Self.send(["error": "A valid scoped local credential is required."], status: 403, to: connection); return
        }
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            Self.send(["error": "Supply question and topic as JSON strings."], status: 400, to: connection); return
        }
        let result: WorkspaceConsultation?
        if request.path == "/v1/receipt", let idString = body["id"] as? String, let id = UUID(uuidString: idString) {
            result = store.consultationReceipt(id, memberID: credential.memberID, twinID: credential.twinID)
        } else if request.path == "/v1/ask", let question = body["question"] as? String, let topic = body["topic"] as? String {
            result = await store.consult(question: question, topic: topic, memberID: credential.memberID, twinID: credential.twinID)
        } else { result = nil }
        guard let result else {
            Self.send(["error": "Request unavailable. The runtime may be busy or the question invalid."], status: 409, to: connection); return
        }
        guard generation == requestGeneration, running, store.data.credentials?.contains(credential) == true else {
            Self.send(["error": "This credential was revoked during the request."], status: 403, to: connection); return
        }
        if result.outcome == .answered || result.outcome == .needsReview {
            guard let member = store.data.members.first(where: { $0.id == credential.memberID }),
                  let twin = store.data.twins.first(where: { $0.id == credential.twinID }),
                  case .allowed(let allowed) = WorkspaceAccessPolicy.evaluate(member: member, twin: twin, documents: store.data.documents, topic: result.topic, at: Date()),
                  let stored = store.data.consultations.first(where: { $0.id == result.id }),
                  Set(stored.sourceIDs).isSubset(of: allowed) else {
                Self.send(["error": "Access changed before delivery. Ask again using the current permissions."], status: 403, to: connection); return
            }
        }
        let canRead = store.data.members.first { $0.id == credential.memberID }?.canReadEvidence == true
        let answer = canRead ? result.answer : result.answer.replacingOccurrences(of: "\\[[a-zA-Z0-9_-]+\\]", with: "", options: .regularExpression)
        let sources = canRead ? store.data.documents.filter { result.sourceIDs.contains($0.id) }.map { ["id": $0.id.uuidString, "title": $0.title, "text": $0.text] } : []
        Self.send(["id": result.id.uuidString, "status": result.outcome.rawValue, "answer": answer, "sources": sources,
                   "notice": "A model answer is not owner approval. No external action was performed."], status: 200, to: connection)
    }

    private static func send(_ object: [String: Any], status: Int, to connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Bounded HTTP/1.1 reader. No chunked bodies, keep-alive, duplicate headers or browser origins.
final class WorkspaceHTTPRequest {
    struct Value { let method: String; let path: String; let headers: [String: String]; let body: Data }
    let connection: NWConnection
    var buffer = Data()
    let deadline = Date().addingTimeInterval(10)
    init(connection: NWConnection) { self.connection = connection }
    func read(completion: @escaping (Value?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] content, _, complete, error in
            if let content { buffer.append(content) }
            guard error == nil, buffer.count <= 65536, Date() < deadline else { completion(nil); return }
            if let separator = buffer.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: buffer[..<separator.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                guard first.count == 3, first[2] == "HTTP/1.1" else { completion(nil); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { completion(nil); return }
                    let name = line[..<colon].lowercased()
                    guard headers[name] == nil else { completion(nil); return }
                    headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard headers["transfer-encoding"] == nil, let length = Int(headers["content-length"] ?? (first[0] == "GET" ? "0" : "")), length >= (first[0] == "GET" ? 0 : 1), length <= 16000 else { completion(nil); return }
                let body = buffer[separator.upperBound...]
                if body.count >= length {
                    guard body.count == length else { completion(nil); return }
                    completion(Value(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body))); return
                }
            }
            if complete { completion(nil) } else { read(completion: completion) }
        }
    }
}
