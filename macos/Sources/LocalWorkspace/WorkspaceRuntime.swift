import Foundation

struct WorkspaceRuntimeStatus: Decodable {
    let switch_ready: Bool?
    let switch_message: String?
    let embedding_ready: Bool
    let ollama_ready: Bool
    let adapters_cached: Bool
    let token: String
    let worker_stage: String?
    let worker_mode: String?
    let workspace_api: Bool?
    let progress_api: Bool?
}

struct WorkspaceRuntimeAnswer: Decodable {
    struct Source: Decodable { let id: String; let title: String; let text: String }
    let status: String
    let answer: String
    let sources: [Source]
    let check_notice: String?
}

struct WorkspaceRuntimeProgress: Decodable {
    let events: [Event]
    struct Event: Decodable {
        let stage: String
        let seconds: Double
        var title: String {
            switch stage {
            case "Loading model": return "Starting the answer pipeline"
            case "Preparing endpoint pipeline": return "Preparing local search and your model connection"
            case "Loading model and local search": return "Loading the local model"
            case "Preparing request": return "Preparing your question"
            case "guardian harm": return "Checking the request with Guardian"
            case "guardian scope": return "Checking relevance to this twin"
            case "clarification": return "Checking whether clarification is needed"
            case "citations": return "Matching answer passages to sources"
            case "query rewrite": return "Refining the search query"
            case "retrieval": return "Finding relevant passages"
            case "answerability": return "Checking whether the sources can answer"
            case "generation": return "Writing an answer"
            case "grounding check": return "Checking the answer against its sources"
            case "repair": return "Revising an answer that failed checks"
            case "repair check": return "Checking the revised answer"
            default: return "Working"
            }
        }
    }
}

/// A native client for the offline service. Redirects cannot move a request off-device.
protocol WorkspaceAnswering {
    func ask(_ question: String, documents: [WorkspaceDocument], configuration: WorkspaceRuntimeConfiguration,
             verbosity: WorkspaceTwin.Verbosity) async throws -> WorkspaceRuntimeAnswer
}

final class WorkspaceRuntimeClient: NSObject, URLSessionTaskDelegate, WorkspaceAnswering {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 260
        config.timeoutIntervalForResource = 270
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    static func endpoint(_ configuration: WorkspaceRuntimeConfiguration, path: String) throws -> URL {
        guard let parts = URLComponents(string: configuration.endpoint),
              parts.scheme == "http", parts.host == "127.0.0.1",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let port = parts.port, (1024...65535).contains(port),
              let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw WorkspaceStorageError.invalid("Use a local endpoint such as http://127.0.0.1:4390. Remote endpoints are not enabled in this workspace.")
        }
        return url
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw WorkspaceStorageError.invalid(body?["error"] as? String ?? "The local runtime did not respond successfully. No cloud fallback was used.")
        }
        return data
    }

    func status(_ configuration: WorkspaceRuntimeConfiguration) async throws -> WorkspaceRuntimeStatus {
        var request = URLRequest(url: try Self.endpoint(configuration, path: "/api/status"))
        request.timeoutInterval = 8
        return try JSONDecoder().decode(WorkspaceRuntimeStatus.self, from: await perform(request))
    }

    func ask(_ question: String, documents: [WorkspaceDocument], configuration: WorkspaceRuntimeConfiguration,
             verbosity: WorkspaceTwin.Verbosity = .standard) async throws -> WorkspaceRuntimeAnswer {
        try await askWithProgress(question, documents: documents, configuration: configuration, verbosity: verbosity) { _ in }
    }

    func askWithProgress(_ question: String, documents: [WorkspaceDocument], configuration: WorkspaceRuntimeConfiguration,
                         verbosity: WorkspaceTwin.Verbosity, subjects: Bool = false, scope: String = "", history: [[String: String]] = [],
                         progress: @escaping @MainActor (WorkspaceRuntimeProgress?) -> Void) async throws -> WorkspaceRuntimeAnswer {
        let state = try await status(configuration)
        let requestID = UUID().uuidString
        let monitor = Task {
            guard state.progress_api == true else { await progress(nil); return }
            while !Task.isCancelled {
                do {
                    var poll = URLRequest(url: try Self.endpoint(configuration, path: "/api/progress"))
                    poll.timeoutInterval = 3
                    poll.setValue(state.token, forHTTPHeaderField: "X-Pilot-Token")
                    poll.setValue(requestID, forHTTPHeaderField: "X-Request-ID")
                    let update = try JSONDecoder().decode(WorkspaceRuntimeProgress.self, from: await perform(poll))
                    try Task.checkCancellation()
                    await progress(update)
                } catch is CancellationError { return }
                catch { if Task.isCancelled { return }; await progress(nil) }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
        defer { monitor.cancel() }
        guard state.workspace_api == true else { throw WorkspaceStorageError.invalid("Update and restart the prepared local runtime to enable native workspace questions.") }
        var request = URLRequest(url: try Self.endpoint(configuration, path: subjects ? "/api/workspace/subjects" : "/api/workspace/ask"))
        request.httpMethod = "POST"
        request.setValue(requestID, forHTTPHeaderField: "X-Request-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(state.token, forHTTPHeaderField: "X-Pilot-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "mode": configuration.backend, "answer_style": verbosity == .brief ? "brief" : "standard",
            "gateway": configuration.backend == "openai-compatible" ? gateway(configuration) : [:],
            "history": history, "scope": scope, "question": question, "documents": documents.map { ["id": $0.id.uuidString, "title": String($0.title.prefix(200)), "text": $0.text] }
        ])
        return try JSONDecoder().decode(WorkspaceRuntimeAnswer.self, from: await perform(request))
    }

    private func gateway(_ configuration: WorkspaceRuntimeConfiguration) -> [String: String] {
        ["url": configuration.modelURL ?? "", "model": configuration.modelName ?? "",
         "key": Keychain.loadServiceToken(service: configuration.modelKeyService) ?? ""]
    }

    func checkModel(_ configuration: WorkspaceRuntimeConfiguration) async throws {
        let state = try await status(configuration)
        var request = URLRequest(url: try Self.endpoint(configuration, path: "/api/model/check"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(state.token, forHTTPHeaderField: "X-Pilot-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["gateway": gateway(configuration)])
        _ = try await perform(request)
    }

    func unload(_ configuration: WorkspaceRuntimeConfiguration) async throws {
        let state = try await status(configuration)
        var request = URLRequest(url: try Self.endpoint(configuration, path: "/api/unload"))
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        request.setValue(state.token, forHTTPHeaderField: "X-Pilot-Token")
        _ = try await perform(request)
    }
}

@MainActor
final class WorkspaceRuntimeController: ObservableObject {
    @Published var message = "Connect the runtime to verify local models."
    @Published var checking = false
    @Published var ready = false
    @Published private(set) var logPath: String?
    let client = WorkspaceRuntimeClient()
    private var process: Process?

    func check(_ configuration: WorkspaceRuntimeConfiguration) async -> Bool {
        checking = true
        defer { checking = false }
        do {
            if configuration.backend == "openai-compatible" {
                try await client.checkModel(configuration)
                ready = true
                message = "Model endpoint answered the test. Retrieval stays on this Mac; selected excerpts go to your endpoint."
                return true
            }
            let status = try await client.status(configuration)
            ready = status.workspace_api == true && status.embedding_ready && (configuration.backend == "granite-switch" ? status.switch_ready == true : configuration.backend == "granite-hf-adapters" ? status.adapters_cached : status.ollama_ready)
            if configuration.backend == "granite-switch" {
                message = status.switch_message ?? "Restart the runtime to enable Granite Switch."
                return ready
            }
            message = ready ? "Local service connected · model files available on this Mac" : status.workspace_api != true ? "Update and restart the prepared runtime to enable native workspace questions." : "Service connected. Model files are missing; prepare the runtime before continuing."
            return ready
        } catch { ready = false; message = error.localizedDescription; return false }
    }

    func launch(_ configuration: WorkspaceRuntimeConfiguration) throws {
        _ = try WorkspaceRuntimeClient.endpoint(configuration, path: "/api/status")
        guard process?.isRunning != true else { return }
        let directory = URL(fileURLWithPath: configuration.serviceDirectory, isDirectory: true)
        let script = directory.appendingPathComponent("server.py")
        guard FileManager.default.isExecutableFile(atPath: configuration.pythonExecutable),
              FileManager.default.fileExists(atPath: script.path) else {
            throw WorkspaceStorageError.invalid("Choose the prepared runtime folder and its .venv/bin/python executable.")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: configuration.pythonExecutable)
        child.arguments = [script.path, "--port", String(URLComponents(string: configuration.endpoint)!.port!)]
        child.currentDirectoryURL = directory
        // The service also enforces offline mode before loading any model libraries.
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"; environment["TRANSFORMERS_OFFLINE"] = "1"
        child.environment = environment
        let log = directory.appendingPathComponent(".cache/native-runtime.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let output = try FileHandle(forWritingTo: log); try output.seekToEnd()
        child.standardOutput = output; child.standardError = output
        try child.run(); process = child
        logPath = log.path
        message = "Starting the local service. Check connection in a moment."
    }

    func stopOwnedService() async {
        guard let process, process.isRunning else { message = "This service was started outside Bestmate. Release its model memory here, or stop it where it was launched."; return }
        // Unload the child model before terminating the HTTP parent process.
        message = "Stop the model using Release model memory, then stop the service."
        process.terminate(); self.process = nil; ready = false
        message = "The service started by Bestmate has stopped."
    }
}
