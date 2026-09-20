import SwiftUI

/// A faint notebook-style grid on paper, used behind the large "hero" Nomi
/// screens so they read like a page from the notes app.
struct NomiGridBackground: View {
    var spacing: CGFloat = 28
    /// Optional mood/brand wash layered over the paper (kept very subtle).
    var tint: Color? = nil

    private let line = Color(red: 0.87, green: 0.89, blue: 0.93)  // NomiTheme.hairline

    var body: some View {
        ZStack {
            NomiTheme.paper
            if let tint {
                LinearGradient(
                    colors: [tint.opacity(0.10), .clear],
                    startPoint: .top, endPoint: .center
                )
            }
            Canvas { ctx, size in
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += spacing
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += spacing
                }
                ctx.stroke(path, with: .color(line.opacity(0.6)), lineWidth: 0.6)
            }
        }
    }
}
