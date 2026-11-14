import ParlaCore
import SwiftUI

/// Colours used across the app. The app uses the iOS system colours, so it matches the look of the Android
/// and desktop apps (which imitate them) and follows dark mode automatically.
enum Palette {
    static let blue = Color(uiColor: .systemBlue)
    static let green = Color(uiColor: .systemGreen)
    static let red = Color(uiColor: .systemRed)
    static let orange = Color(uiColor: .systemOrange)
    static let purple = Color(uiColor: .systemPurple)
    static let teal = Color(uiColor: .systemTeal)
    static let gray = Color(uiColor: .systemGray)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let fill = Color(uiColor: .tertiarySystemFill)
    static let fillLight = Color(uiColor: .quaternarySystemFill)
    static let separator = Color(uiColor: .separator)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let tertiary = Color(uiColor: .tertiaryLabel)

    static let greenDark = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
        : UIColor(red: 0.14, green: 0.54, blue: 0.24, alpha: 1) })
    static let redDark = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1.0, green: 0.41, blue: 0.38, alpha: 1)
        : UIColor(red: 0.84, green: 0.0, blue: 0.08, alpha: 1) })
    static let greenTint = green.opacity(0.14)
    static let redTint = red.opacity(0.12)
    static let blueTint = blue.opacity(0.12)
    static let orangeTint = orange.opacity(0.14)
}

extension Color {
    /// Colour from 0xRRGGBB (course files store unit colours like this).
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

// ---------------------------------------------------------------------- buttons

/// Big rounded button as used for the main actions ("Prüfen", "Weiter", "Lektion starten").
struct PrimaryButtonStyle: ButtonStyle {
    enum Kind { case filled, tinted, success, destructive }
    var kind: Kind = .filled
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let (bg, fg): (Color, Color) = {
            switch kind {
            case .filled: return (Palette.blue, .white)
            case .tinted: return (Palette.blueTint, Palette.blue)
            case .success: return (Palette.green, .white)
            case .destructive: return (Palette.red, .white)
            }
        }()
        return configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .background(isEnabled ? bg : Palette.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(isEnabled ? fg : Palette.tertiary)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primary(_ kind: PrimaryButtonStyle.Kind) -> PrimaryButtonStyle { PrimaryButtonStyle(kind: kind) }
}

// ---------------------------------------------------------------------- small building blocks

/// Rounded coloured square with an emoji, like iOS Settings icons.
struct IconTile: View {
    let emoji: String
    let color: Color
    var size: CGFloat = 36
    var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(dimmed ? Palette.fill : color.opacity(0.18))
            .frame(width: size, height: size)
            .overlay(Text(emoji).font(.system(size: size * 0.52)).opacity(dimmed ? 0.45 : 1))
    }
}

struct ProgressBar: View {
    let value: Double
    var color: Color = Palette.blue
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.fill)
                Capsule().fill(color).frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

/// Five bars showing how well a finished unit is remembered.
struct StrengthBars: View {
    let strength: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i <= strength ? (strength < 4 ? Palette.orange : Palette.green) : Palette.fill)
                    .frame(width: 6, height: CGFloat(6 + i * 3))
            }
        }
        .accessibilityLabel("Stärke \(strength) von 5")
    }
}

/// Lays out views in rows, wrapping to the next row when the width is used up (word chips, prompt words).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    var centered = false

    private func makeRows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = makeRows(subviews, width: width)
        var height: CGFloat = 0
        var maxRow: CGFloat = 0
        for (n, row) in rows.enumerated() where !row.isEmpty {
            height += (row.map { $0.1.height }.max() ?? 0) + (n > 0 ? lineSpacing : 0)
            let rowWidth = row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(0, row.count - 1))
            maxRow = max(maxRow, rowWidth)
        }
        return CGSize(width: width.isFinite ? width : maxRow, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in makeRows(subviews, width: bounds.width) where !row.isEmpty {
            let rowHeight = row.map { $0.1.height }.max() ?? 0
            let rowWidth = row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(0, row.count - 1))
            var x = centered ? bounds.minX + max(0, (bounds.width - rowWidth) / 2) : bounds.minX
            for (i, size) in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }
}

/// Name of a course level as shown in the unit list.
func levelName(_ level: String?) -> String {
    guard let level = level?.uppercased() else { return "Einheiten" }
    switch level {
    case "A1": return "Stufe A1 · Einstieg"
    case "A2": return "Stufe A2 · Grundlagen"
    case "B1": return "Stufe B1 · Fortgeschritten"
    case "B2": return "Stufe B2 · Selbstständig"
    default: return "Stufe \(level)"
    }
}

/// Applies the app's "Große Schrift" option on top of the system text size.
struct LargeTextModifier: ViewModifier {
    let on: Bool
    @Environment(\.dynamicTypeSize) private var current

    @ViewBuilder
    func body(content: Content) -> some View {
        if on {
            content.dynamicTypeSize(current < .xxLarge ? .xxLarge : current)
        } else {
            content
        }
    }
}
