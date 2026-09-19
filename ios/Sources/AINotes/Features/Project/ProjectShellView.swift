import Combine
import SwiftUI

/// Owns the live tutor + chat for one open notebook so navigation only has one
/// `@StateObject` to create (avoids flaky double-init on push).
@MainActor
final class NotebookSession: ObservableObject {
    let project: Project
    let shadowing: ShadowingEngine
    let chat: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    init(project: Project) {
        self.project = project
        let engine = ShadowingEngine(projectId: project.id)
        self.shadowing = engine
        self.chat = ChatViewModel(project: project, shadowing: engine)
        // Nested ObservableObjects don't auto-refresh the parent view.
        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        chat.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}

/// A single notebook: handwriting canvas + optional side assistant. Sources open
/// in a sheet; the live tutor lives in the mascot and can post into chat.
struct ProjectShellView: View {
    @StateObject private var session: NotebookSession
    @State private var showSources = false
    @State private var showChat = false

    init(project: Project) {
        _session = StateObject(wrappedValue: NotebookSession(project: project))
    }

    var body: some View {
        HStack(spacing: 0) {
            NotesView(project: session.project, shadowing: session.shadowing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showChat {
                Divider()
                ChatView(model: session.chat)
                    .frame(width: 340)
                    .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(session.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    session.shadowing.toggleVoiceMute()
                } label: {
                    Label(
                        session.shadowing.isListening ? "Stop" : "Talk",
                        systemImage: session.shadowing.isListening ? "mic.fill" : "mic.slash.fill"
                    )
                }
                .accessibilityLabel(session.shadowing.isListening ? "Stop listening" : "Talk to tutor")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showChat.toggle() }
                } label: {
                    Label(
                        showChat ? "Hide Assistant" : "Assistant",
                        systemImage: showChat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right"
                    )
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSources = true
                } label: { Label("Sources", systemImage: "doc.text.magnifyingglass") }
            }
        }
        .sheet(isPresented: $showSources) {
            NavigationStack {
                SourcesView(project: session.project)
            }
        }
        .onAppear {
            session.chat.shadowing = session.shadowing
        }
        .onReceive(session.shadowing.$chatNotices) { notices in
            // Important: ignore empty publishes. Clearing chatNotices also fires
            // this publisher — without the guard that becomes an infinite loop
            // and freezes the app the moment a notebook opens.
            guard !notices.isEmpty else { return }
            let taken = session.shadowing.consumeChatNotices()
            guard !taken.isEmpty else { return }
            showChat = true
            session.chat.ingestNotices(taken)
        }
    }
}
