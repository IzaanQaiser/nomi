import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    let text: String
    let citations: [Citation]
}

@Observable
final class ChatViewModel {
    let project: Project
    var messages: [ChatMessage] = []
    var input = ""
    var isSending = false

    init(project: Project) { self.project = project }

    func send() async {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        input = ""
        messages.append(ChatMessage(isUser: true, text: question, citations: []))
        isSending = true
        defer { isSending = false }
        do {
            let resp = try await APIClient.shared.chat(projectId: project.id, question: question)
            messages.append(ChatMessage(isUser: false, text: resp.answer, citations: resp.citations))
        } catch {
            messages.append(ChatMessage(isUser: false, text: "Error: \(error.localizedDescription)", citations: []))
        }
    }
}

struct ChatView: View {
    @State private var model: ChatViewModel

    init(project: Project) {
        _model = State(initialValue: ChatViewModel(project: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesList
            Divider()
            inputBar
        }
        .background(.background)
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
                        Text("Ask about this notebook's sources. Answers are grounded only in what you've added.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(model.messages) { message in
                        MessageBubble(message: message).id(message.id)
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

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
            Text(message.text)
                .padding(10)
                .background(
                    message.isUser ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.regularMaterial),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)

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
