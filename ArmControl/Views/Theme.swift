import SwiftUI

/// PivotXP brand palette, carried over from AuraBooth's `Brand`.
///
/// ⚠️ A trap recorded in that file, worth not repeating: `red` was once aliased to `mint`, so every
/// error, warning and disconnected indicator rendered in the exact colour of success — "Not
/// connected" was green, and the arm's safety warnings were green. **Mint is for accents and GO
/// only.** Failure uses `danger`, attention uses `caution`, and nothing else may borrow them.
enum Pivot {
    static let mint     = Color(red: 0x48 / 255, green: 0xF4 / 255, blue: 0xAD / 255) // #48F4AD
    static let purple   = Color(red: 0xAA / 255, green: 0x61 / 255, blue: 0xEA / 255) // #AA61EA
    static let blue     = Color(red: 0x67 / 255, green: 0xA6 / 255, blue: 0xFB / 255) // #67A6FB
    static let deepBlue = Color(red: 0x11 / 255, green: 0x36 / 255, blue: 0x57 / 255) // #113657 — arm UI

    /// A REAL red, for failure states only.
    static let danger = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1)
        : UIColor(red: 0.86, green: 0.24, blue: 0.27, alpha: 1) })

    /// Amber for "needs attention but not broken" — faults you can clear, limits you are near.
    static let caution = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1.00, green: 0.72, blue: 0.30, alpha: 1)
        : UIColor(red: 0.85, green: 0.52, blue: 0.05, alpha: 1) })
}

/// Design system. Semantic system colours underneath (so contrast and accessibility behave like the
/// rest of iPadOS), Pivot brand on top for accent and state.
enum Theme {

    // MARK: Colour

    static let background = Color(uiColor: .systemBackground)
    static let grouped    = Color(uiColor: .systemGroupedBackground)
    static let card       = Color(uiColor: .secondarySystemGroupedBackground)
    static let fill       = Color(uiColor: .tertiarySystemFill)

    static let label     = Color(uiColor: .label)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let tertiary  = Color(uiColor: .tertiaryLabel)
    static let separator = Color(uiColor: .separator)

    static let accent = Pivot.mint
    static let good   = Pivot.mint
    static let warn   = Pivot.caution
    static let bad    = Pivot.danger

    // MARK: Metrics
    //
    // Continuous ("squircle") corners throughout — the circular-arc default is the single most
    // common tell that a UI was not built by someone looking at Apple's.

    static let cardRadius: CGFloat = 16
    static let heroRadius: CGFloat = 26
    static let controlRadius: CGFloat = 12
}

// MARK: - Liquid Glass

/// Builds the Glass value outside any `@ViewBuilder`.
///
/// Configuring it inline in the modifier below does not work: a ViewBuilder body treats
/// `if let tint { glass = ... }` as a conditional *view*, and the whole thing fails to compile with
/// the memorable "type '()' cannot conform to 'View'".
@available(iOS 26.0, *)
private func pivotGlassValue(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

extension View {
    /// Liquid Glass where the OS has it, a material where it does not.
    ///
    /// The app still targets iOS 17, so this cannot be called unguarded — `glassEffect` is 26.0+.
    /// Wrapping it once here keeps every call site clean and means the fallback is decided in one
    /// place rather than at twenty.
    @ViewBuilder
    func pivotGlass(in shape: some Shape,
                    tint: Color? = nil,
                    interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(pivotGlassValue(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(tint?.opacity(0.16) ?? Color.clear, in: shape)
                .background(.ultraThinMaterial, in: shape)
        }
    }

    /// Groups adjacent glass elements so they refract as one surface rather than fighting.
    @ViewBuilder
    func pivotGlassGroup() -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { self }
        } else {
            self
        }
    }
}

// MARK: - Components

/// A grouped card. Matches the metrics of an inset-grouped `List` section so cards and Forms can
/// sit in the same screen without looking like two different apps.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Label {
                    Text(title)
                } icon: {
                    if let systemImage { Image(systemName: systemImage) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.secondary)
                .labelStyle(.titleAndIcon)
            }

            content

            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pivotGlass(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// Small status capsule. Colour carries the state; the label carries the meaning.
struct StatusPill: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            // Neutral glass, coloured LABEL. Tinting the glass with the same colour as the label
            // renders the text invisible — the pills became solid blobs. Third time this bit:
            // the rule is that glass is neutral and colour lives in the content, everywhere.
            .pivotGlass(in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

/// A labelled value row, the shape Settings uses everywhere.
struct DetailRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 16)
            trailing
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.secondary)
        }
    }
}

/// A slider with the value shown where Apple shows it — trailing, monospaced, in the header row.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.body)
                Spacer()
                Text(format(value))
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .tint(Theme.accent)
            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}

/// A label for a destructive row action.
///
/// ⚠️ `Button(role: .destructive)` inside a List or Form reddens its TEXT but leaves the SF Symbol
/// on the app tint — so Disconnect, Power cycle and Stop all shipped with a **mint** glyph, the
/// colour this app uses for GO, sitting on the control that stops things. Same family as the
/// mint-on-mint pills, and the same rule fixes it: colour belongs to the content, so state it.
struct DestructiveLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(Theme.bad)
    }
}

/// Reports a view's size to an ancestor.
///
/// ⚠️ Use this instead of wrapping a screen in a `GeometryReader` when the only thing needed is the
/// size. A GeometryReader reports the frame INCLUDING the safe-area region an inset bar occupies,
/// so content sized from it lays out underneath the bar — which is how the console's last row of
/// presets ended up half-hidden behind the STOP bar.
struct SizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
