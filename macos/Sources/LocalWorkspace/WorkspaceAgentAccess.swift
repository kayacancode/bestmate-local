import SwiftUI

struct WorkspaceAgentAccess: View {
    @EnvironmentObject var store: NativeWorkspaceStore
    @ObservedObject var gateway: WorkspaceGateway
    @State private var memberID: UUID?
    @State private var twinID: UUID?
    @State private var name = "Local agent"
    @State private var newToken: String?
    var body: some View {
        WorkspacePanel {
            Text("Connect an agent on this Mac").font(.title3.weight(.semibold))
            Text("Each credential uses one person’s permissions and one twin’s knowledge, topics and hours. The endpoint is available only on this Mac while Bestmate is open.").foregroundStyle(.secondary)
            Text(gateway.message).font(.caption.monospaced()).textSelection(.enabled)
            Button(gateway.running ? "Stop agent access" : "Start local endpoint") {
                if gateway.running { gateway.stop() }
                else { do { try gateway.start(store: store) } catch { store.error = error.localizedDescription } }
            }.buttonStyle(.borderedProminent)
        }
        WorkspacePanel {
            Text("Issue a scoped credential").font(.headline)
            TextField("Agent label", text: $name)
            Picker("Person", selection: $memberID) { Text("Choose a person").tag(UUID?.none); ForEach(store.data.members) { Text($0.name).tag(Optional($0.id)) } }
            Picker("Twin", selection: $twinID) { Text("Choose a twin").tag(UUID?.none); ForEach(store.data.twins) { Text($0.name).tag(Optional($0.id)) } }
            Button("Create credential") {
                guard let memberID, let twinID, store.data.twins.first(where: { $0.id == twinID })?.memberIDs.contains(memberID) == true else {
                    store.error = "This person needs access to the selected twin first."; return
                }
                do {
                    let token = try WorkspaceGateway.newToken()
                    let credential = WorkspaceCredential(name: name, memberID: memberID, twinID: twinID, tokenHash: WorkspaceGateway.hash(token))
                    if store.update({ value in
                        if value.credentials == nil { value.credentials = [] }
                        value.credentials?.append(credential)
                        value.events.append(WorkspaceEvent(title: "Agent credential issued", detail: name))
                    }) { newToken = token }
                } catch { store.error = error.localizedDescription }
            }.disabled(memberID == nil || twinID == nil || name.isEmpty)
            if let token = newToken {
                Text("Copy this credential now. Only its hash is saved.").font(.callout)
                Text(token).font(.caption.monospaced()).textSelection(.enabled)
                Button("Copy credential") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token, forType: .string) }
                Button("Hide credential") { newToken = nil }
            }
            DisclosureGroup("Request format") {
                Text("POST http://127.0.0.1:4392/v1/ask\nAuthorization: Bearer YOUR_CREDENTIAL\nContent-Type: application/json\n\n{\"topic\":\"Engineering\",\"question\":\"What should I check before retrying?\"}")
                    .font(.caption.monospaced()).textSelection(.enabled).padding(.top, 8)
                Text("Use a topic granted to both the person and twin. A held answer returns a review receipt, not the draft. No invitation or message is sent by creating a credential.").font(.caption).foregroundStyle(.secondary)
                Text("To collect a held answer after approval, POST {\"id\":\"RESPONSE_ID\"} to /v1/receipt with the same credential. Permissions and hours are checked again.").font(.caption).foregroundStyle(.secondary)
            }
        }
        ForEach(store.data.credentials ?? []) { credential in
            HStack {
                VStack(alignment: .leading) {
                    Text(credential.name).font(.headline)
                    Text("\(store.data.members.first { $0.id == credential.memberID }?.name ?? "Removed person") · \(store.data.twins.first { $0.id == credential.twinID }?.name ?? "Removed twin")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revoke") {
                    store.update { value in
                        value.credentials?.removeAll { $0.id == credential.id }
                        value.events.append(WorkspaceEvent(title: "Agent credential revoked", detail: credential.name))
                    }
                    newToken = nil
                }
            }.padding(.vertical, 8)
        }
    }
}
