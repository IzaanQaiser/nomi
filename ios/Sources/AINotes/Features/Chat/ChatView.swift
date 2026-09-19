import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case text
        case solutionOffer(mistakeKey: String, summary: String, count: Int)
    }

    let id: UUID
    let isUser: Bool
    let text: String
    let citations: [Citation]
    let kind: Kind

    init(
        id: UUID = UUID(),
        isUser: Bool,
        text: String,
        citations: [Citation] = [],
        kind: Kind = .text
    ) {
        self.id = id
        self.isUser = isUser
        self.text = text
        self.citations = citations
        self.kind = kind
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    let project: Project
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isSending = false
    @Published var solutionSheet: SolutionSheetState?
    @Published var teachMeToast = false

    weak var shadowing: ShadowingEngine?

    init(project: Project, shadowing: ShadowingEngine? = nil) {
        self.project = project
        self.shadowing = shadowing
    }

    func ingestNotices(_ notices: [TutorChatNotice]) {
        for notice in notices {
            switch notice {
            case let .solutionOffer(key, summary, count):
                let text = """
                You've hit a similar issue \(count) times: “\(summary)”

                I can show the full worked solution now if you want.
                """
                messages.append(
                    ChatMessage(
                        isUser: false,
                        text: text,
                        kind: .solutionOffer(mistakeKey: key, summary: summary, count: count)
                    )
                )
            }
        }
    }

    func send() async {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        input = ""
        messages.append(ChatMessage(isUser: true, text: question))
        isSending = true
        defer { isSending = false }
        do {
            let resp = try await APIClient.shared.chat(projectId: project.id, question: question)
            messages.append(ChatMessage(isUser: false, text: resp.answer, citations: resp.citations))
        } catch {
            messages.append(ChatMessage(isUser: false, text: "Error: \(error.localizedDescription)"))
        }
    }

    func revealSolution(summary: String) async {
        guard !isSending else { return }
        guard let payload = shadowing?.solutionRequestPayload() else {
            messages.append(ChatMessage(isUser: false, text: "I need to see the page first — keep the notebook open and try again."))
            return
        }
        isSending = true
        defer { isSending = false }
        messages.append(ChatMessage(isUser: true, text: "Show me the solution."))
        do {
            let resp = try await APIClient.shared.revealSolution(
                projectId: project.id,
                imageBase64: payload.imageBase64,
                problemContext: payload.problem,
                recentContext: payload.memory,
                mistakeSummary: summary
            )
            solutionSheet = SolutionSheetState(solution: resp.solution, problem: resp.problem)
            messages.append(ChatMessage(isUser: false, text: "Here's the full solution — opened beside your notes."))
        } catch {
            messages.append(ChatMessage(isUser: false, text: "Couldn't load the solution: \(error.localizedDescription)"))
        }
    }

    func teachMeTapped() {
        // Dud for now — lesson mode comes later.
        teachMeToast = true
    }
}

struct SolutionSheetState: Identifiable, Equatable {
    let id = UUID()
    let solution: String
    let problem: String?
}

struct ChatView: View {
    @ObservedObject var model: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesList
            Divider()
            inputBar
        }
        .background(.background)
        .sheet(item: $model.solutionSheet) { sheet in
            SolutionRevealView(
                problem: sheet.problem,
                solution: sheet.solution,
                onTeachMe: { model.teachMeTapped() }
            )
        }
        .alert("Lesson mode coming soon", isPresented: $model.teachMeToast) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Teach me will walk you through a curated lesson on this concept. Not wired up yet.")
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
            Text("Assistant").font(.headline)
            Spacer()
        }
        .padding()
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty {
                        Text("Ask about this notebook's sources. When Nomi catches the same mistake a few times, a solution unlock will show up here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(model.messages) { message in
                        MessageBubble(message: message) {
                            if case let .solutionOffer(_, summary, _) = message.kind {
                                Task { await model.revealSolution(summary: summary) }
                            }
                        }
                        .id(message.id)
                    }
                    if model.isSending {
                        HStack { ProgressView(); Text("Thinking…").foregroundStyle(.secondary) }
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: model.messages.count) {
                if let last = model.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask a question…", text: $model.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { Task { await model.send() } }
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.isSending)
        }
        .padding()
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    var onShowSolution: (() -> Void)?

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
            Text(message.text)
                .padding(10)
                .background(
                    message.isUser ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.regularMaterial),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)

            if case .solutionOffer = message.kind {
                Button {
                    onShowSolution?()
                } label: {
                    Label("Show full solution", systemImage: "lightbulb.max.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 4)
            }

            if !message.citations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sources").font(.caption2).foregroundStyle(.secondary)
                    ForEach(message.citations) { citation in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "text.quote").font(.caption2)
                            VStack(alignment: .leading) {
                                Text(citation.sourceTitle).font(.caption).bold()
                                Text(citation.snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal)
    }
}

/// Side popup with the worked solution + a placeholder Teach me CTA.
struct SolutionRevealView: View {
    @Environment(\.dismiss) private var dismiss

    let problem: String?
    let solution: String
    let onTeachMe: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let problem, !problem.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Problem").font(.caption).foregroundStyle(.secondary)
                            Text(problem).font(.body.weight(.medium))
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Solution").font(.caption).foregroundStyle(.secondary)
                        Text(solution)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    Button {
                        onTeachMe()
                    } label: {
                        Label("Teach me", systemImage: "graduationcap.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)

                    Text("Teach me will open a guided lesson on this concept later. For now it's a placeholder.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("Full solution")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
