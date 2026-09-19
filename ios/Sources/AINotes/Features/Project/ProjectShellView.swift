import SwiftUI

/// A single notebook: the handwriting canvas fills the screen. Sources open in a
/// sheet; the live tutor lives in the mascot in the canvas's top-right corner.
struct ProjectShellView: View {
    let project: Project

    @State private var showSources = false

    var body: some View {
        NotesView(project: project)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSources = true
                    } label: { Label("Sources", systemImage: "doc.text.magnifyingglass") }
                }
            }
            .sheet(isPresented: $showSources) {
                NavigationStack {
                    SourcesView(project: project)
                }
            }
    }
}
