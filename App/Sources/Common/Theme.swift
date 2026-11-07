import SwiftUI
import M2DCore

enum Theme {
    static let panel = Color(white: 0.13)
    static let panelHeader = Color(white: 0.17)
    static let canvasBackground = Color(white: 0.09)
    static let separator = Color(white: 0.25)
    static let accent = Color(red: 0.36, green: 0.62, blue: 1.0)
    static let keyColor = Color(red: 1.0, green: 0.78, blue: 0.25)
    static let warpColor = Color(red: 0.35, green: 0.85, blue: 0.65)
    static let rotationColor = Color(red: 1.0, green: 0.5, blue: 0.35)
    static let meshColor = Color(red: 0.55, green: 0.7, blue: 1.0)
    static let sidebarWidth: CGFloat = 290
}

extension Vec2 {
    var cgPoint: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
    init(_ p: CGPoint) { self.init(Float(p.x), Float(p.y)) }
}

/// Section header used inside panels.
struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panelHeader)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(_ title: String) { self.title = title; trailing = { EmptyView() } }
}

/// Transparent-background checkerboard.
struct Checkerboard: View {
    var size: CGFloat = 12
    var body: some View {
        Canvas { ctx, s in
            let cols = Int(s.width / size) + 1, rows = Int(s.height / size) + 1
            ctx.fill(Path(CGRect(origin: .zero, size: s)), with: .color(Color(white: 0.22)))
            var p = Path()
            for r in 0..<rows { for c in 0..<cols where (r + c) % 2 == 0 {
                p.addRect(CGRect(x: CGFloat(c) * size, y: CGFloat(r) * size, width: size, height: size))
            }}
            ctx.fill(p, with: .color(Color(white: 0.27)))
        }
    }
}

/// Numeric field + slider pair used by inspectors.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Float
    var range: ClosedRange<Float>
    var format: String = "%.2f"
    var onEditingChanged: (Bool) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format, value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
        }
    }
}

struct IconButton: View {
    let systemName: String
    var help: String = ""
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 34)
                .background(active ? Theme.accent.opacity(0.3) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(active ? Theme.accent : Color.primary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
