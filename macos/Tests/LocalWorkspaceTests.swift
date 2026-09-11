import XCTest
import AppKit
import CoreText
@testable import BestmateLocal

final class LocalWorkspaceTests: XCTestCase {
    func testLegacyRuntimeConfigurationStillDecodes() throws {
        let old = Data(#"{"endpoint":"http://127.0.0.1:4390","backend":"granite-hf-adapters","pythonExecutable":"","serviceDirectory":""}"#.utf8)
        let config = try JSONDecoder().decode(WorkspaceRuntimeConfiguration.self, from: old)
        XCTAssertNil(config.modelURL)
        XCTAssertNil(config.modelName)
        XCTAssertEqual(config.backend, "granite-hf-adapters")
    }

    func testTelegramRoutingRequiresAddressedGroupTextAndPrefersSenderOverride() {
        let group = WorkspaceTelegramRoute(chatID: "-100123", senderID: "", memberID: UUID(), twinID: UUID(), topic: "General")
        let individual = WorkspaceTelegramRoute(chatID: "-100123", senderID: "42", memberID: UUID(), twinID: UUID(), topic: "General")
        var message: [String: Any] = ["chat": ["id": -100123, "type": "supergroup"], "from": ["id": 42, "is_bot": false], "text": "/ask@Example_bot What next?"]
        XCTAssertEqual(WorkspaceTelegramConnection.incoming(["message": message], username: "Example_bot", routes: [group, individual])?.0, individual)
        XCTAssertEqual(WorkspaceTelegramConnection.incoming(["message": message], username: "Example_bot", routes: [group])?.1, "42")
        message["text"] = "ordinary group conversation"
        XCTAssertNil(WorkspaceTelegramConnection.incoming(["message": message], username: "Example_bot", routes: [group]))
        message["text"] = "/ask@Other_bot What next?"
        XCTAssertNil(WorkspaceTelegramConnection.incoming(["message": message], username: "Example_bot", routes: [group]))
        message["text"] = "/ask@Example_bot What next?"
        message["sender_chat"] = ["id": -100123]
        XCTAssertNil(WorkspaceTelegramConnection.incoming(["message": message], username: "Example_bot", routes: [group]))
        XCTAssertNil(WorkspaceTelegramConnection.incoming(["edited_message": message], username: "Example_bot", routes: [group]))
    }

    func testSubjectRestrictionsAreOptionalWithoutChangingSourceBoundaries() {
        var person = LocalWorkspaceMember(name: "Example", role: "Client")
        var twin = WorkspaceTwin(name: "Example", purpose: "Help")
        twin.memberIDs = [person.id]
        XCTAssertEqual(WorkspaceAccessPolicy.sharedSubjects(member: person, twin: twin), ["General"])
        twin.topics = ["Architecture"]
        XCTAssertEqual(WorkspaceAccessPolicy.sharedSubjects(member: person, twin: twin), ["Architecture"])
        person.topics = ["Budget"]
        XCTAssertTrue(WorkspaceAccessPolicy.sharedSubjects(member: person, twin: twin).isEmpty)
    }

    func testSharedSubjectsUseOnlyThePersonTwinIntersection() {
        var person = LocalWorkspaceMember(name: "Example", role: "Client")
        person.topics = ["ExampleProject", "Writing"]
        var twin = WorkspaceTwin(name: "Example twin", purpose: "Help")
        twin.memberIDs = [person.id]; twin.topics = ["ExampleProject", "Engineering"]
        XCTAssertEqual(WorkspaceAccessPolicy.sharedSubjects(member: person, twin: twin), ["ExampleProject"])
        twin.topics = ["Engineering"]
        XCTAssertTrue(WorkspaceAccessPolicy.sharedSubjects(member: person, twin: twin).isEmpty)
        twin.topics = ["ExampleProject"]; twin.memberIDs = []
        XCTAssertTrue(WorkspaceAccessPolicy.sharedSubjects(member: person, twin: twin).isEmpty)
        XCTAssertTrue(WorkspaceAccessPolicy.sharedSubjects(member: nil, twin: twin).isEmpty)
    }

    @MainActor
    func testWhatsAppReceiverVerifiesChallengeAndRejectsUnsignedPost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(repository: WorkspaceRepository(directory: directory))
        store.whatsApp.start(store: store, token: "fictional", secret: "test-secret", verifyToken: "test-verify", numberID: "123", version: "v23.0")
        defer { store.whatsApp.stop() }
        for _ in 0..<30 where !store.whatsApp.running { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(store.whatsApp.running)
        let session = URLSession(configuration: .ephemeral)
        let (body, response) = try await session.data(from: URL(string: "http://127.0.0.1:4393/whatsapp?hub.mode=subscribe&hub.verify_token=test-verify&hub.challenge=12345")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "12345")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:4393/whatsapp")!)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        let (_, rejected) = try await session.data(for: request)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertTrue(store.data.consultations.isEmpty)
    }

    func testWhatsAppWebhookSignatureRejectsTampering() {
        let body = Data("{\"object\":\"whatsapp_business_account\"}".utf8)
        // Independently generated HMAC-SHA256 test fixture.
        let signature = "sha256=60b2e09855b25cf88d59953a4025f83bc48cd03865abe988e974b754c7a285e8"
        XCTAssertTrue(WorkspaceWhatsAppConnection.verified(body: body, signature: signature, secret: "test-secret"))
        XCTAssertFalse(WorkspaceWhatsAppConnection.verified(body: body + Data(" ".utf8), signature: signature, secret: "test-secret"))
        XCTAssertFalse(WorkspaceWhatsAppConnection.verified(body: body, signature: signature, secret: "wrong-secret"))
        XCTAssertFalse(WorkspaceWhatsAppConnection.verified(body: body, signature: "sha256=invalid", secret: "test-secret"))
    }

    func testWhatsAppIncomingIgnoresWrongBusinessNumberAndNonTextEvents() {
        let payload: [String: Any] = ["object": "whatsapp_business_account", "entry": [["changes": [["field": "messages", "value": ["metadata": ["phone_number_id": "123"], "messages": [["id": "one", "type": "text"], ["id": "two", "type": "image"]]]]]]]]
        XCTAssertEqual(WorkspaceWhatsAppConnection.incoming(payload, numberID: "123").count, 1)
        XCTAssertTrue(WorkspaceWhatsAppConnection.incoming(payload, numberID: "456").isEmpty)
        XCTAssertTrue(WorkspaceWhatsAppConnection.incoming([:], numberID: "123").isEmpty)
    }

    func testSlackChannelRouteAllowsAnySenderButPrefersIndividualMapping() {
        let channel = WorkspaceSlackRoute(channelID: "C123", slackUserID: "", memberID: UUID(), twinID: UUID(), topic: "General")
        let individual = WorkspaceSlackRoute(channelID: "C123", slackUserID: "U123", memberID: UUID(), twinID: UUID(), topic: "General")
        let event: [String: Any] = ["type": "app_mention", "channel": "C123", "user": "U123"]
        XCTAssertEqual(WorkspaceSlackConnection.route(event, routes: [channel, individual]), individual)
        XCTAssertEqual(WorkspaceSlackConnection.route(event.merging(["user": "U999"]) { _, new in new }, routes: [channel, individual]), channel)
        XCTAssertNil(WorkspaceSlackConnection.route(event.merging(["channel": "C999"]) { _, new in new }, routes: [channel, individual]))
    }

    @MainActor
    func testChannelOnlyTelegramMappingCreatesBoundedAudienceAndReusesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(repository: WorkspaceRepository(directory: directory))
        let shared = WorkspaceDocument(title: "Shared", text: "Shared material", origin: "test", teamVisible: true)
        let privateDoc = WorkspaceDocument(title: "Private", text: "Private material", origin: "test")
        var twin = WorkspaceTwin(name: "Test", purpose: "Help")
        twin.sourceIDs = [shared.id, privateDoc.id]
        store.update { $0.documents = [shared, privateDoc]; $0.twins = [twin] }
        XCTAssertTrue(store.saveTelegramMapping(channel: " -100123 ", sender: "", memberID: nil, twinID: twin.id, subject: "General"))
        let route = try XCTUnwrap(store.data.telegramRoutes?.first)
        let audience = try XCTUnwrap(store.data.members.first { $0.id == route.memberID })
        XCTAssertTrue(route.senderID.isEmpty)
        XCTAssertEqual(audience.sourceIDs, [shared.id])
        XCTAssertFalse(audience.canReadEvidence)
        XCTAssertTrue(store.data.twins[0].memberIDs.contains(audience.id))
        XCTAssertTrue(store.saveTelegramMapping(channel: "-100123", sender: "", memberID: nil, twinID: twin.id, subject: "General"))
        XCTAssertEqual(store.data.members.count, 1)
        XCTAssertEqual(store.data.telegramRoutes?.count, 1)
    }

    @MainActor
    func testChannelOnlySlackMappingCreatesBoundedAudienceAndReusesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(repository: WorkspaceRepository(directory: directory))
        let shared = WorkspaceDocument(title: "Shared", text: "Shared material", origin: "test", teamVisible: true)
        let privateDoc = WorkspaceDocument(title: "Private", text: "Private material", origin: "test")
        var twin = WorkspaceTwin(name: "Test", purpose: "Help")
        twin.sourceIDs = [shared.id, privateDoc.id]
        store.update { $0.documents = [shared, privateDoc]; $0.twins = [twin] }
        XCTAssertTrue(store.saveSlackMapping(channel: " C123 ", sender: "", memberID: nil, twinID: twin.id, subject: "General"))
        let route = try XCTUnwrap(store.data.slackRoutes?.first)
        let audience = try XCTUnwrap(store.data.members.first { $0.id == route.memberID })
        XCTAssertTrue(route.slackUserID.isEmpty)
        XCTAssertEqual(audience.sourceIDs, [shared.id])
        XCTAssertFalse(audience.canReadEvidence)
        XCTAssertTrue(store.data.twins[0].memberIDs.contains(audience.id))
        XCTAssertTrue(store.saveSlackMapping(channel: "C123", sender: "", memberID: nil, twinID: twin.id, subject: "General"))
        XCTAssertEqual(store.data.members.count, 1)
        XCTAssertEqual(store.data.slackRoutes?.count, 1)
    }

    func testSlackRoutesRequireExactSenderAndChannel() {
        let route = WorkspaceSlackRoute(channelID: "C123", slackUserID: "U123", memberID: UUID(), twinID: UUID(), topic: "General")
        let event: [String: Any] = ["type": "app_mention", "channel": "C123", "user": "U123"]
        XCTAssertEqual(WorkspaceSlackConnection.route(event, routes: [route]), route)
        for change in [["user": "U999"], ["channel": "C999"], ["type": "message"], ["bot_id": "B123"], ["subtype": "message_changed"]] {
            XCTAssertNil(WorkspaceSlackConnection.route(event.merging(change) { _, new in new }, routes: [route]))
        }
        XCTAssertNil(WorkspaceSlackConnection.route(event, routes: []))
    }

    func testSlackRouteConfigurationPersistsWithoutTokens() throws {
        var data = LocalWorkspaceData()
        data.slackRoutes = [WorkspaceSlackRoute(channelID: "C123", slackUserID: "U123", memberID: UUID(), twinID: UUID(), topic: "General")]
        let encoded = try JSONEncoder().encode(data)
        XCTAssertEqual(try JSONDecoder().decode(LocalWorkspaceData.self, from: encoded), data)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("xoxb-"))
    }

    func testGranolaFoldersAndFilteredPagination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GranolaFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GranolaApiClient(apiKey: "test-key", session: session)
        let folders = try await client.listFolders()
        XCTAssertEqual(folders.map { $0.path(in: folders) }, ["Engineering", "Engineering / Planning"])
        let notes = try await client.listNotes(createdAfter: nil, folderID: "fol_team", limit: nil)
        XCTAssertEqual(notes.map(\.id), ["not_team1", "not_team2"])
    }

    func testGranolaFolderSelectionDeduplicatesOverlapsAndClearsOnlyVisibleNotes() {
        func note(_ id: String) -> GranolaApiClient.Note {
            .init(noteId: id, title: id, ownerName: nil, ownerEmail: nil, summary: nil, createdAt: nil)
        }
        let first = [note("one"), note("shared")]
        let second = [note("shared"), note("two")]
        var selection = GranolaNoteSelection()
        selection.select(first)
        selection.select(second)
        XCTAssertEqual(selection.notes.count, 3)
        XCTAssertEqual(selection.count(in: first), 2)
        selection.deselect(first)
        XCTAssertEqual(selection.notes.map(\.id), ["two"])
        selection.clear()
        XCTAssertTrue(selection.notes.isEmpty)
    }

    func testGranolaQuickSelectionFitsCapacityAndReplacesAnOversizedSelection() {
        func note(_ id: String) -> GranolaApiClient.Note {
            .init(noteId: id, title: id, ownerName: nil, ownerEmail: nil, summary: nil, createdAt: nil)
        }
        let notes = (0..<50).map { note(String($0)) }
        var selection = GranolaNoteSelection()
        selection.select(notes)
        selection.selectFirstNew(notes, limit: 30, importedIDs: [])
        XCTAssertEqual(selection.notes.count, 30)
        XCTAssertTrue(selection.contains("0"))
        XCTAssertFalse(selection.contains("30"))
        selection.selectFirstNew([notes[0], notes[0]] + notes, limit: 2, importedIDs: ["0"])
        XCTAssertEqual(Set(selection.notes.map(\.id)), ["1", "2"])
        selection.selectFirstNew(notes, limit: 0, importedIDs: [])
        XCTAssertTrue(selection.notes.isEmpty)
    }

    func testGranolaFolderPathsHandleMissingParentsAndCycles() {
        let missing = GranolaApiClient.Folder(id: "a", name: "Private", parentFolderID: "unavailable")
        XCTAssertEqual(missing.path(in: [missing]), "Private")
        let a = GranolaApiClient.Folder(id: "a", name: "A", parentFolderID: "b")
        let b = GranolaApiClient.Folder(id: "b", name: "B", parentFolderID: "a")
        XCTAssertEqual(a.path(in: [a, b]), "B / A")
    }

    @MainActor
    func testPurposePersistsAndSourceAdviceDoesNotImportOrTrain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(repository: WorkspaceRepository(directory: directory))
        store.update { $0.purpose = .leadership; $0.onboardingStep = 2 }
        let fake = RecordingWorkspaceAnswerer(); store.answering = fake
        let source = WorkspaceDocument(title: "Preview", text: "Require a reversible pilot before approving expansion.", origin: "Granola preview")
        let unrelated = WorkspaceDocument(title: "Office schedule", text: "The kitchen closes at six.", origin: "Granola preview")
        let before = store.data
        let result = await store.suggestSources([source, unrelated], for: .leadership)
        XCTAssertEqual(result?.sources, [source])
        XCTAssertEqual(fake.documents, [source, unrelated])
        XCTAssertEqual(fake.question, WorkspacePurpose.leadership.sourceQuestion)
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try store.repository.load().purpose, .leadership)
        XCTAssertEqual(try store.repository.load().onboardingStep, 2)
        let emptyResult = await store.suggestSources([], for: .leadership)
        XCTAssertNil(emptyResult)
        XCTAssertEqual(fake.calls, 1)
    }

    @MainActor
    func testEscalationsIdentifySharedRequestsOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(repository: WorkspaceRepository(directory: directory))
        let sharedID = UUID(), ownerID = UUID()
        var shared = WorkspaceConsultation(memberID: UUID(), twinID: UUID(), topic: "Engineering", question: "Retry?", answer: "Ask first", outcome: .needsReview, sourceIDs: [])
        shared.reviewID = sharedID
        var owner = WorkspaceConsultation(topic: "Engineering", question: "Why?", answer: "Review this", outcome: .needsReview, sourceIDs: [])
        owner.reviewID = ownerID
        store.update { $0.consultations = [shared, owner] }
        XCTAssertEqual(store.sharedRequest(for: sharedID)?.id, shared.id)
        XCTAssertNil(store.sharedRequest(for: ownerID))
        XCTAssertNil(store.sharedRequest(for: UUID()))
    }

    func testFolderDiscoveryShowsEvidenceAndStaysInsideChosenFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "Decision: keep the scope small because rollback matters.".write(to: root.appendingPathComponent("decision.md"), atomically: true, encoding: .utf8)
        try "Coffee at noon.".write(to: root.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try "Secret decision".write(to: root.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        try "Dependency decision".write(to: root.appendingPathComponent("node_modules/ignored.md"), atomically: true, encoding: .utf8)
        let outside = directory.appendingPathComponent("outside.md")
        try "Outside decision".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.md"), withDestinationURL: outside)
        try String(repeating: "decision ", count: 6000).write(to: root.appendingPathComponent("too-long.txt"), atomically: true, encoding: .utf8)
        let found = try WorkspaceFileSearch.search(folder: root, query: "decision, scope, DECISION")
        XCTAssertEqual(found.matches.map(\.relativePath), ["decision.md"])
        XCTAssertEqual(found.matches[0].matchedTerms, ["decision", "scope"])
        XCTAssertTrue(found.matches[0].excerpt.contains("rollback"))
        XCTAssertFalse(found.matches[0].document.teamVisible)
        XCTAssertTrue(found.skipped >= 2)
        XCTAssertThrowsError(try WorkspaceFileSearch.search(folder: root, query: " , "))
    }

    @MainActor
    func testDiscoveredImportsAreAtomicPrivateAndDeduplicated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(repository: WorkspaceRepository(directory: directory))
        var source = WorkspaceDocument(title: "Decision", text: "Use a small pilot.", origin: "decision.md", teamVisible: true)
        source.externalID = "local-file:/chosen/decision.md"
        XCTAssertTrue(store.importDiscoveredSources([source]))
        let originalID = store.data.documents[0].id
        XCTAssertFalse(store.data.documents[0].teamVisible)
        store.update { $0.documents[0].teamVisible = true }
        source.id = UUID(); source.text = "Use a reversible pilot."
        XCTAssertTrue(store.importDiscoveredSources([source]))
        XCTAssertEqual(store.data.documents.count, 1)
        XCTAssertEqual(store.data.documents[0].id, originalID)
        XCTAssertTrue(store.data.documents[0].teamVisible)
        let before = store.data
        var invalid = source; invalid.externalID = "local-file:/chosen/empty.md"; invalid.text = ""
        var valid = source; valid.externalID = "local-file:/chosen/second.md"
        XCTAssertFalse(store.importDiscoveredSources([valid, invalid]))
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try store.repository.load(), before)
    }

    func testGranolaOfficialSummaryAndPagination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GranolaFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GranolaApiClient(apiKey: "test-key", session: session)
        let notes = try await client.listNotes(createdAfter: nil)
        XCTAssertEqual(notes.map(\.id), ["not_first", "not_second"])
        let summary = try await client.fetchSummary(noteId: "not_first")
        XCTAssertEqual(summary, "# Approved summary")
        do {
            _ = try await GranolaApiClient(apiKey: "invalid", session: session).listNotes(createdAfter: nil)
            XCTFail("Invalid key accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("rejected")) }
    }

    @MainActor
    func testRemovingSourceClearsGrantsAndInvalidatesJudgmentWithoutErasingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(repository: WorkspaceRepository(directory: directory))
        XCTAssertTrue(store.addDocument(title: "Article", text: "Ask before retrying", origin: "test"))
        let doc = try XCTUnwrap(store.data.documents.first)
        var member = LocalWorkspaceMember(name: "Teammate", role: "Developer")
        member.sourceIDs = [doc.id]
        var twin = WorkspaceTwin(name: "Helper", purpose: "Guide work")
        twin.sourceIDs = [doc.id]
        var decision = WorkspaceJudgment(question: "Retry?", answer: "Ask first", reason: "Avoid duplicates", sourceIDs: [doc.id], sourceSnapshots: [doc], topic: "Engineering")
        decision.status = .approved
        store.update { $0.members = [member]; $0.twins = [twin]; $0.judgments = [decision] }
        XCTAssertTrue(store.evidenceIsCurrent(decision))
        XCTAssertTrue(store.removeDocument(doc.id))
        XCTAssertTrue(store.data.documents.isEmpty)
        XCTAssertTrue(store.data.members[0].sourceIDs.isEmpty)
        XCTAssertTrue(store.data.twins[0].sourceIDs.isEmpty)
        XCTAssertFalse(store.evidenceIsCurrent(decision))
        XCTAssertEqual(store.data.judgments[0].sourceSnapshots, [doc])
        XCTAssertEqual(try store.repository.load(), store.data)
    }

    @MainActor
    func testGranolaImportsAreAtomicAndPreserveIdentityAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(repository: WorkspaceRepository(directory: directory))
        XCTAssertTrue(store.importGranolaNotes([("one", "Planning", "Ask first")]))
        let original = try XCTUnwrap(store.data.documents.first)
        XCTAssertFalse(original.teamVisible)
        store.update { $0.documents[0].teamVisible = true }
        XCTAssertTrue(store.importGranolaNotes([("one", "Planning updated", "Always ask first")]))
        XCTAssertEqual(store.data.documents.count, 1)
        XCTAssertEqual(store.data.documents[0].id, original.id)
        XCTAssertTrue(store.data.documents[0].teamVisible)
        XCTAssertEqual(store.data.documents[0].text, "Always ask first")
        let before = store.data
        XCTAssertFalse(store.importGranolaNotes([("two", "Valid", "Some text"), ("three", "Invalid", "")]))
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try store.repository.load(), before)
    }

    @MainActor
    func testLocalFolderAndPDFImportsPreservePrivateDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = directory.appendingPathComponent("vault/subfolder")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "Ask before retrying a partial write.".write(to: vault.appendingPathComponent("runbook.md"), atomically: true, encoding: .utf8)
        try "Hidden material".write(to: vault.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        let store = NativeWorkspaceStore(repository: WorkspaceRepository(directory: directory.appendingPathComponent("state")))
        store.importMarkdownFolder(directory.appendingPathComponent("vault"))
        XCTAssertEqual(store.data.documents.count, 1)
        XCTAssertEqual(store.data.documents[0].title, "runbook")
        XCTAssertFalse(store.data.documents[0].teamVisible)
        let pdf = directory.appendingPathComponent("guide.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.textPosition = CGPoint(x: 30, y: 250)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Escalate partial writes.", attributes: [.font: NSFont.systemFont(ofSize: 12)])), context)
        context.endPDFPage(); context.closePDF()
        store.importFiles([pdf])
        XCTAssertEqual(store.data.documents.count, 2)
        XCTAssertTrue(store.data.documents[1].text.contains("Escalate partial writes"))
        XCTAssertFalse(store.data.documents[1].teamVisible)
        XCTAssertEqual(try store.repository.load(), store.data)
    }

    @MainActor
    func testPreparedRuntimeCanBeStartedCheckedAndStoppedByNativeController() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("experiments/local-rag-pilot")
        let python = root.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("Prepare the local runtime for the lifecycle integration check.") }
        var configuration = WorkspaceRuntimeConfiguration()
        configuration.endpoint = "http://127.0.0.1:4394"
        configuration.serviceDirectory = root.path; configuration.pythonExecutable = python.path
        let controller = WorkspaceRuntimeController()
        try controller.launch(configuration)
        for _ in 0..<20 {
            if await controller.check(configuration) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(controller.ready, controller.message)
        XCTAssertNotNil(controller.logPath)
        do { try await controller.client.unload(configuration) }
        catch { await controller.stopOwnedService(); throw error }
        await controller.stopOwnedService()
        XCTAssertFalse(controller.ready)
    }
    @MainActor
    func testReviewPreservesEvidenceAndUndoRestoresPriorVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(repository: WorkspaceRepository(directory: directory))
        XCTAssertTrue(store.addDocument(title: "Policy", text: "Ask before retrying a partial write.", origin: "test"))
        let doc = try XCTUnwrap(store.data.documents.first)
        let draft = WorkspaceJudgment(question: "Retry?", answer: "Ask first.", reason: "", sourceIDs: [doc.id], sourceSnapshots: [doc], topic: "Engineering")
        store.update { $0.judgments.append(draft) }
        store.approve(draft.id, answer: "Ask first.", reason: "", scope: .project)
        XCTAssertEqual(store.data.judgments[0].status, .draft)
        store.approve(draft.id, answer: "Ask first.", reason: "Avoid duplicate writes.", scope: .project)
        XCTAssertEqual(store.data.judgments[0].status, .approved)
        store.revision(store.data.judgments[0])
        let revision = store.data.judgments[1]
        store.approve(revision.id, answer: "Escalate to owner.", reason: "Owner checks repeatability.", scope: .project)
        XCTAssertEqual(store.data.judgments[0].status, .superseded)
        store.review(revision.id, status: .undone)
        XCTAssertEqual(store.data.judgments[0].status, .approved)
        XCTAssertEqual(store.data.judgments[1].status, .undone)
        store.update { $0.documents[0].text = "The policy changed." }
        XCTAssertFalse(store.evidenceIsCurrent(store.data.judgments[0]))
        XCTAssertEqual(store.data.judgments[0].sourceSnapshots[0].text, doc.text)
        XCTAssertEqual(try store.repository.load(), store.data)
    }

    func testRuntimeRejectsRemoteEndpointsAndCredentialHashesAreStable() throws {
        var config = WorkspaceRuntimeConfiguration()
        XCTAssertEqual(try WorkspaceRuntimeClient.endpoint(config, path: "/api/ask").host, "127.0.0.1")
        for invalid in ["https://example.com", "http://127.0.0.1:4390@evil.test", "http://127.0.0.1:4390/path", "http://localhost:4390", "http://127.0.0.1:4390?redirect=1"] {
            config.endpoint = invalid
            XCTAssertThrowsError(try WorkspaceRuntimeClient.endpoint(config, path: "/api/ask"))
        }
    }

    @MainActor
    func testConsultationFiltersBeforeRetrievalAndHoldsUnapprovedAnswers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(repository: WorkspaceRepository(directory: directory))
        let shared = WorkspaceDocument(title: "Runbook", text: "Ask before retrying.", origin: "test", teamVisible: true)
        let secret = WorkspaceDocument(title: "Private", text: "Never disclose this private source.", origin: "test")
        var member = LocalWorkspaceMember(name: "Junior", role: "Developer")
        member.sourceIDs = [shared.id, secret.id]; member.topics = ["Engineering"]
        var twin = WorkspaceTwin(name: "Pair", purpose: "Pair programming")
        twin.memberIDs = [member.id]; twin.sourceIDs = member.sourceIDs; twin.topics = member.topics
        twin.weekdays = [1,2,3,4,5,6,7]; twin.startMinute = 0; twin.endMinute = 1439
        // Put the local clock at noon without altering policy evaluation's actual date.
        let hour = Calendar.current.component(.hour, from: Date())
        twin.timeZone = TimeZone(secondsFromGMT: TimeZone.current.secondsFromGMT() + (12 - hour) * 3600)?.identifier ?? "UTC"
        store.update { $0.documents = [shared, secret]; $0.members = [member]; $0.twins = [twin] }
        let fake = RecordingWorkspaceAnswerer(); store.answering = fake
        let result = await store.consult(question: "Retry?", topic: "Engineering", memberID: member.id, twinID: twin.id)
        XCTAssertEqual(fake.documents.map(\.id), [shared.id])
        XCTAssertEqual(result?.outcome, .needsReview)
        XCTAssertFalse(result?.answer.contains("Ask before retrying") ?? true)
        XCTAssertEqual(store.data.judgments.first?.status, .draft)
        XCTAssertEqual(store.data.consultations.count, 1)
        let draft = try XCTUnwrap(store.data.judgments.first)
        store.approve(draft.id, answer: "Ask the owner before retrying.", reason: "Avoid duplicates.", scope: .instance)
        let receipt = store.consultationReceipt(try XCTUnwrap(result?.id), memberID: member.id, twinID: twin.id)
        XCTAssertEqual(receipt?.outcome, .answered)
        XCTAssertEqual(receipt?.answer, "Ask the owner before retrying.")
        store.review(draft.id, status: .undone)
        XCTAssertEqual(store.consultationReceipt(result!.id, memberID: member.id, twinID: twin.id)?.outcome, .needsReview)
        store.update { $0.members[0].canAsk = false }
        let denied = await store.consult(question: "Retry?", topic: "Engineering", memberID: member.id, twinID: twin.id)
        XCTAssertEqual(denied?.outcome, .denied)
        XCTAssertEqual(fake.calls, 1)
        XCTAssertEqual(store.data.consultations.count, 2)
    }

    @MainActor
    func testGatewayRequiresCredentialAndEnforcesBoundScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(repository: WorkspaceRepository(directory: directory))
        let doc = WorkspaceDocument(title: "Shared", text: "Ask before retrying.", origin: "test", teamVisible: true)
        var member = LocalWorkspaceMember(name: "Junior", role: "Developer")
        member.sourceIDs = [doc.id]; member.topics = ["Engineering"]
        var twin = WorkspaceTwin(name: "Pair", purpose: "Help")
        twin.memberIDs = [member.id]; twin.sourceIDs = [doc.id]; twin.topics = member.topics
        twin.weekdays = [1,2,3,4,5,6,7]; twin.startMinute = 0; twin.endMinute = 1439; twin.requiresOwnerReview = false
        let token = try WorkspaceGateway.newToken()
        let credential = WorkspaceCredential(name: "Test agent", memberID: member.id, twinID: twin.id, tokenHash: WorkspaceGateway.hash(token))
        store.update { $0.documents = [doc]; $0.members = [member]; $0.twins = [twin]; $0.credentials = [credential] }
        let fake = RecordingWorkspaceAnswerer(); store.answering = fake
        try store.gateway.start(store: store)
        defer { store.gateway.stop() }
        for _ in 0..<30 where !store.gateway.running { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(store.gateway.running)
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        func request(_ credential: String?) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:4392/v1/ask")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{\"question\":\"Retry?\",\"topic\":\"Engineering\"}".utf8)
            if let credential { request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization") }
            let (data, response) = try await session.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let unauthorized = try await request(nil)
        XCTAssertEqual(unauthorized.1.statusCode, 403); XCTAssertEqual(fake.calls, 0)
        let authorized = try await request(token)
        XCTAssertEqual(authorized.1.statusCode, 200); XCTAssertEqual(fake.calls, 1)
        let response = try JSONSerialization.jsonObject(with: authorized.0) as! [String: Any]
        XCTAssertEqual((response["sources"] as? [Any])?.count, 0)
        XCTAssertFalse((response["answer"] as? String)?.contains(doc.id.uuidString) ?? true)
        store.update { $0.credentials = [] }
        let revoked = try await request(token)
        XCTAssertEqual(revoked.1.statusCode, 403); XCTAssertEqual(fake.calls, 1)
    }

    @MainActor
    func testWeeklyScheduleFindsMostRecentOccurrence() throws {
        var skill = WorkspaceSkill(name: "Review", instructions: "Review the runbook")
        skill.trigger = .weekly; skill.weekday = 2; skill.minute = 9 * 60; skill.timeZone = "UTC"
        let format = ISO8601DateFormatter()
        XCTAssertEqual(NativeWorkspaceStore.latestOccurrence(skill, at: format.date(from: "2026-09-09T12:00:00Z")!), format.date(from: "2026-09-07T09:00:00Z"))
    }

    @MainActor
    func testScheduledSkillCreatesOneReviewAndDoesNotRepeatTheSameOccurrence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkspaceStore(repository: WorkspaceRepository(directory: directory))
        let doc = WorkspaceDocument(title: "Runbook", text: "Ask before retrying.", origin: "test")
        var skill = WorkspaceSkill(name: "Daily review", instructions: "What should I check before retrying?")
        skill.trigger = .daily; skill.minute = 0; skill.timeZone = "UTC"; skill.enabled = true
        store.update { $0.documents = [doc]; $0.skills = [skill] }
        let fake = RecordingWorkspaceAnswerer(); store.answering = fake
        await store.runDueSkills()
        await store.runDueSkills()
        XCTAssertEqual(fake.calls, 1)
        XCTAssertEqual(store.data.judgments.count, 1)
        XCTAssertEqual(store.data.judgments[0].status, .draft)
        XCTAssertNotNil(store.data.skills[0].lastRunAt)
        XCTAssertNotNil(store.data.skills[0].latestDraft)
        XCTAssertEqual(try store.repository.load(), store.data)
    }
    func testAtomicRepositoryRoundTripAndCorruptStateIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WorkspaceRepository(directory: directory)
        var value = LocalWorkspaceData()
        value.name = "Local test"
        try repository.save(value)
        XCTAssertEqual(try repository.load(), value)
        try Data("broken".utf8).write(to: repository.fileURL)
        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try String(contentsOf: repository.fileURL), "broken")
    }

    func testPermissionIntersectionExcludesPrivateAndUnassignedSources() {
        let shared = WorkspaceDocument(title: "Shared", text: "Example", origin: "test", teamVisible: true)
        let secret = WorkspaceDocument(title: "Private", text: "Private example", origin: "test")
        var member = LocalWorkspaceMember(name: "Sam", role: "Developer")
        member.sourceIDs = [shared.id, secret.id]; member.topics = ["Engineering"]
        var twin = WorkspaceTwin(name: "Mentor", purpose: "Teach")
        twin.memberIDs = [member.id]; twin.sourceIDs = member.sourceIDs; twin.topics = member.topics
        twin.timeZone = "UTC"; twin.weekdays = [1,2,3,4,5,6,7]; twin.startMinute = 0; twin.endMinute = 1439
        let date = ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z")!
        XCTAssertEqual(WorkspaceAccessPolicy.evaluate(member: member, twin: twin, documents: [shared, secret], topic: "Engineering", at: date), .allowed([shared.id]))
        member.canAsk = false
        if case .denied = WorkspaceAccessPolicy.evaluate(member: member, twin: twin, documents: [shared], topic: "Engineering", at: date) {} else { XCTFail("Revoked consultation must be denied") }
    }

    func testOvernightAvailabilityUsesStartDayAndEndIsExclusive() {
        let doc = WorkspaceDocument(title: "Shared", text: "Example", origin: "test", teamVisible: true)
        var member = LocalWorkspaceMember(name: "Sam", role: "Developer")
        member.sourceIDs = [doc.id]; member.topics = ["Engineering"]
        var twin = WorkspaceTwin(name: "Night mentor", purpose: "Teach")
        twin.memberIDs = [member.id]; twin.sourceIDs = member.sourceIDs; twin.topics = member.topics
        twin.timeZone = "UTC"; twin.weekdays = [2]; twin.startMinute = 22 * 60; twin.endMinute = 2 * 60
        let format = ISO8601DateFormatter()
        XCTAssertEqual(WorkspaceAccessPolicy.evaluate(member: member, twin: twin, documents: [doc], topic: "Engineering", at: format.date(from: "2026-09-08T01:59:00Z")!), .allowed([doc.id]))
        XCTAssertEqual(WorkspaceAccessPolicy.evaluate(member: member, twin: twin, documents: [doc], topic: "Engineering", at: format.date(from: "2026-09-08T02:00:00Z")!), .outsideHours)
    }
}

private final class RecordingWorkspaceAnswerer: WorkspaceAnswering {
    var documents: [WorkspaceDocument] = []
    var calls = 0
    var question = ""
    func ask(_ question: String, documents: [WorkspaceDocument], configuration: WorkspaceRuntimeConfiguration, verbosity: WorkspaceTwin.Verbosity) async throws -> WorkspaceRuntimeAnswer {
        self.documents = documents; self.question = question; calls += 1
        return WorkspaceRuntimeAnswer(status: "answered", answer: "Ask before retrying. [\(documents[0].id)]", sources: documents.map { WorkspaceRuntimeAnswer.Source(id: $0.id.uuidString, title: $0.title, text: $0.text) }, check_notice: nil)
    }
}

private final class GranolaFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key"
        let body: String
        if request.url!.path.hasSuffix("folders") {
            if request.url!.query?.contains("cursor=") == true {
                body = ##"{"folders":[{"id":"fol_child","name":"Planning","parent_folder_id":"fol_team"}],"hasMore":false,"cursor":null}"##
            } else {
                body = ##"{"folders":[{"id":"fol_team","name":"Engineering","parent_folder_id":null}],"hasMore":true,"cursor":"folder-page2"}"##
            }
        } else if request.url!.query?.contains("folder_id=fol_team") == true {
            if request.url!.query?.contains("cursor=") == true {
                body = ##"{"notes":[{"id":"not_team2","title":"Child note"}],"hasMore":false}"##
            } else {
                body = ##"{"notes":[{"id":"not_team1","title":"Team note"}],"hasMore":true,"cursor":"notes-page2"}"##
            }
        } else if request.url!.path.hasSuffix("not_first") {
            body = ##"{"summary_text":"Approved summary","summary_markdown":"# Approved summary","private_notes_text":"Do not import this"}"##
        } else if request.url!.query?.contains("cursor=") == true {
            body = ##"{"notes":[{"id":"not_second","title":"Second"}],"hasMore":false}"##
        } else {
            body = ##"{"notes":[{"id":"not_first","title":"First"}],"hasMore":true,"cursor":"page2"}"##
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: authorized ? 200 : 401, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
