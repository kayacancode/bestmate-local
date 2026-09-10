import SwiftUI

/// The default workspace is independent of legacy cloud authentication and storage.
@main
struct BestmateApp: App {
    @StateObject private var workspace: NativeWorkspaceStore
    init() {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["BESTMATE_TEST_WORKSPACE"], path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") {
            _workspace = StateObject(wrappedValue: NativeWorkspaceStore(repository: WorkspaceRepository(directory: URL(fileURLWithPath: path))))
            return
        }
        #endif
        _workspace = StateObject(wrappedValue: NativeWorkspaceStore())
    }
    var body: some Scene {
        WindowGroup(id: "main") {
            NativeWorkspaceRoot()
                .environmentObject(workspace)
                .frame(minWidth: 960, minHeight: 700)
                .task {
                    while !Task.isCancelled {
                        await workspace.runDueSkills()
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                }
        }
        .defaultSize(width: 1240, height: 860)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Bestmate") { NSApp.orderFrontStandardAboutPanel() }
            }
        }
        MenuBarExtra("Bestmate", systemImage: "brain.head.profile") {
            LocalWorkspaceMenu().environmentObject(workspace)
        }
    }
}
private struct LocalWorkspaceMenu: View {
    @EnvironmentObject var workspace: NativeWorkspaceStore
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(workspace.data.name)
        Text("\(workspace.data.judgments.filter { $0.status == .draft }.count) decisions to review")
        Divider()
        Button("Open Bestmate") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit Bestmate") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
