import SwiftUI

/// Direction artistique « Minuit », version verre :
/// - fond : nuit bleue profonde, halo coloré flouté qui suit la chaîne sélectionnée ;
/// - surfaces : verre translucide (rangées, panneaux, capsule de navigation) ;
/// - focus : **inversion** — l'élément focalisé devient une pastille claire à texte nuit ;
/// - braise pour le direct, lune pour les accents, violet pour le replay ;
/// - titres de section en petites capitales espacées.
enum Theme {
    enum Palette {
        static let night = Color(red: 0.027, green: 0.043, blue: 0.086)          // #070B16
        static let nightRaised = Color(red: 0.063, green: 0.102, blue: 0.200)    // #101A33
        static let surface = Color(red: 0.067, green: 0.110, blue: 0.200)        // #111C33
        static let surfaceFocused = Color(red: 0.094, green: 0.149, blue: 0.290) // #18264A
        static let stroke = Color.white.opacity(0.08)

        /// Verre : rangées et panneaux au repos.
        static let glass = Color.white.opacity(0.085)
        /// Verre plus marqué : élément sélectionné mais non focalisé.
        static let glassSelected = Color.white.opacity(0.18)
        /// Pastille de focus (focus inversé).
        static let focusFill = Color(red: 0.945, green: 0.957, blue: 0.984)      // #F1F4FB
        /// Texte sur la pastille de focus.
        static let onFocus = Color(red: 0.047, green: 0.071, blue: 0.137)        // #0C1223
        static let onFocusSecondary = Color(red: 0.047, green: 0.071, blue: 0.137).opacity(0.62)

        static let textPrimary = Color(red: 0.933, green: 0.949, blue: 0.980)    // #EEF2FA
        static let textSecondary = Color(red: 0.690, green: 0.737, blue: 0.835)  // #B0BCD5
        static let textTertiary = Color(red: 0.471, green: 0.529, blue: 0.651)   // #7887A6

        static let moon = Color(red: 0.561, green: 0.722, blue: 1.0)             // #8FB8FF
        static let ember = Color(red: 1.0, green: 0.420, blue: 0.333)            // #FF6B55
        static let archive = Color(red: 0.706, green: 0.612, blue: 1.0)          // #B49CFF
        static let danger = Color(red: 1.0, green: 0.431, blue: 0.431)

        static let backdrop = LinearGradient(colors: [nightRaised, night], startPoint: .top, endPoint: .bottom)
        static let scrimBottom = LinearGradient(colors: [night.opacity(0), night.opacity(0.92)], startPoint: .top, endPoint: .bottom)
        static let scrimTop = LinearGradient(colors: [night.opacity(0.85), night.opacity(0)], startPoint: .top, endPoint: .bottom)
        static let scrimLeading = LinearGradient(colors: [night.opacity(0.96), night.opacity(0.0)], startPoint: .leading, endPoint: .trailing)
    }

    enum Typeface {
        static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
        static func title(_ size: CGFloat = 38) -> Font { .system(size: size, weight: .semibold) }
        static func programme(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .semibold, design: .serif) }
        static func body(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .regular) }
        static func label(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .semibold) }
        static func caption(_ size: CGFloat = 21) -> Font { .system(size: size, weight: .medium) }
        static func section(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .semibold) }
        static func time(_ size: CGFloat = 24) -> Font { .system(size: size, weight: .medium).monospacedDigit() }
    }

    enum Metrics {
        static let safeHorizontal: CGFloat = 80
        static let safeVertical: CGFloat = 50
        static let corner: CGFloat = 18
        static let cornerSmall: CGFloat = 14
        static let logoSize = CGSize(width: 120, height: 72)
        static let rowLogo = CGSize(width: 150, height: 84)
    }

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.16)
        static let standard = Animation.easeInOut(duration: 0.28)
        static let panel = Animation.spring(response: 0.38, dampingFraction: 0.88)
        static let backdrop = Animation.easeInOut(duration: 0.6)
    }
}

// MARK: - Retour vers la barre du haut

private struct BackToTopBarKey: EnvironmentKey {
    static var defaultValue: () -> Void { {} }
}

extension EnvironmentValues {
    /// Bouton Retour : remonte le focus vers la capsule de navigation (comportement tvOS
    /// standard des onglets). Depuis la capsule, Retour quitte l'application.
    var backToTopBar: () -> Void {
        get { self[BackToTopBarKey.self] }
        set { self[BackToTopBarKey.self] = newValue }
    }
}

// MARK: - Focus inversé

private struct OnFocusKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Vrai à l'intérieur d'un élément focalisé à fond clair : les textes passent en nuit.
    var onFocusPill: Bool {
        get { self[OnFocusKey.self] }
        set { self[OnFocusKey.self] = newValue }
    }
}

/// Couleurs de texte qui s'adaptent au focus inversé.
private struct AdaptiveText: ViewModifier {
    enum Level { case primary, secondary, tertiary }
    let level: Level
    @Environment(\.onFocusPill) private var onPill

    func body(content: Content) -> some View {
        content.foregroundStyle(color)
    }

    private var color: Color {
        switch (level, onPill) {
        case (.primary, false): return Theme.Palette.textPrimary
        case (.secondary, false): return Theme.Palette.textSecondary
        case (.tertiary, false): return Theme.Palette.textTertiary
        case (.primary, true): return Theme.Palette.onFocus
        case (.secondary, true), (.tertiary, true): return Theme.Palette.onFocusSecondary
        }
    }
}

extension View {
    func primaryText() -> some View { modifier(AdaptiveText(level: .primary)) }
    func secondaryText() -> some View { modifier(AdaptiveText(level: .secondary)) }
    func tertiaryText() -> some View { modifier(AdaptiveText(level: .tertiary)) }

    /// Titre de section en petites capitales espacées (« CATÉGORIES »).
    func sectionHeader() -> some View {
        self.font(Theme.Typeface.section())
            .textCase(.uppercase)
            .tracking(1.6)
            .foregroundStyle(Theme.Palette.textTertiary)
    }
}

/// Rangée de verre : translucide au repos, pastille claire au focus.
struct GlassRowButtonStyle: ButtonStyle {
    var isSelected = false
    var cornerRadius: CGFloat = Theme.Metrics.cornerSmall
    var horizontalPadding: CGFloat = 22
    var verticalPadding: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, isSelected: isSelected, cornerRadius: cornerRadius,
             horizontalPadding: horizontalPadding, verticalPadding: verticalPadding)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let cornerRadius: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .environment(\.onFocusPill, isFocused)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isFocused ? Theme.Palette.focusFill : (isSelected ? Theme.Palette.glassSelected : Theme.Palette.glass))
                )
                .shadow(color: isFocused ? Color.black.opacity(0.35) : .clear, radius: 18, y: 8)
                .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.03 : 1))
                .animation(Theme.Motion.quick, value: isFocused)
                .animation(Theme.Motion.quick, value: configuration.isPressed)
        }
    }
}

/// Élément de barre latérale : transparent au repos, verre si sélectionné, pastille au focus.
struct SidebarButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, isSelected: isSelected)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .environment(\.onFocusPill, isFocused)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Capsule(style: .continuous)
                        .fill(isFocused ? Theme.Palette.focusFill : (isSelected ? Theme.Palette.glassSelected : Color.clear))
                )
                .scaleEffect(isFocused ? 1.03 : 1)
                .animation(Theme.Motion.quick, value: isFocused)
        }
    }
}

/// Bouton rond d'icône (lecteur, barres d'outils).
struct RoundIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 76

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, diameter: diameter)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let diameter: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.Palette.onFocus : Theme.Palette.textPrimary)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(isFocused ? Theme.Palette.focusFill : Color.white.opacity(0.16)))
                .scaleEffect(isFocused ? 1.1 : 1)
                .animation(Theme.Motion.quick, value: isFocused)
        }
    }
}

/// Carte focalisable (accueil, fiches) : verre, pastille claire au focus.
struct MinuitCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Theme.Metrics.corner

    func makeBody(configuration: Configuration) -> some View {
        GlassRowButtonStyle(cornerRadius: cornerRadius, horizontalPadding: 0, verticalPadding: 0).makeBody(configuration: configuration)
    }
}

/// Compatibilité : ancien style de ligne, désormais rangée de verre.
typealias MinuitRowButtonStyle = GlassRowButtonStyle

/// Fine barre de progression.
struct ProgressLine: View {
    var progress: Double
    var tint: Color = Theme.Palette.ember
    var height: CGFloat = 4
    @Environment(\.onFocusPill) private var onPill

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(onPill ? Theme.Palette.onFocus.opacity(0.15) : Color.white.opacity(0.16))
                Capsule().fill(tint).frame(width: max(height, proxy.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: height)
    }
}

/// Pastille d'état (« DIRECT », « REPLAY »).
struct StatusBadge: View {
    enum Kind { case live, replay, startOver }
    var kind: Kind

    var body: some View {
        Text(label)
            .font(Theme.Typeface.caption(19).weight(.bold))
            .tracking(1.2)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Capsule().fill(color))
            .foregroundStyle(.white)
    }

    private var label: String {
        switch kind {
        case .live: return "DIRECT"
        case .replay: return "REPLAY"
        case .startOver: return "DEPUIS LE DÉBUT"
        }
    }

    private var color: Color {
        switch kind {
        case .live: return Theme.Palette.ember
        case .replay, .startOver: return Theme.Palette.archive.opacity(0.9)
        }
    }
}

/// Petite étiquette de métadonnée (« FHD », « Replay 7 j »).
struct MetaTag: View {
    let text: String
    var systemImage: String?
    @Environment(\.onFocusPill) private var onPill

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(Theme.Typeface.caption(18).weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Capsule().fill(onPill ? Theme.Palette.onFocus.opacity(0.1) : Color.white.opacity(0.12)))
        .foregroundStyle(onPill ? Theme.Palette.onFocusSecondary : Theme.Palette.textSecondary)
    }
}

private let clockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "fr_FR")
    formatter.dateFormat = "HH:mm"
    return formatter
}()

extension Date {
    /// « 20:45 » (24 h) dans le fuseau de l'appareil, quelle que soit la langue de l'Apple TV.
    var clockText: String {
        clockFormatter.timeZone = .current
        return clockFormatter.string(from: self)
    }
}

/// Emblème de Minuit : croissant de lune et symbole « lecture » braise, comme l'icône
/// de l'application (scripts/make_assets.py).
struct MinuitMark: View {
    var size: CGFloat

    var body: some View {
        let r = size * 0.40
        ZStack {
            Circle()
                .fill(Theme.Palette.moon)
                .frame(width: r * 2, height: r * 2)
                .mask(
                    ZStack {
                        Rectangle()
                        Circle()
                            .frame(width: r * 2, height: r * 2)
                            .offset(x: r * 0.52, y: -r * 0.18)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                )
            PlayTriangle()
                .fill(Theme.Palette.ember)
                .frame(width: size * 0.18, height: size * 0.20)
                .offset(x: r * 0.95, y: r * 0.78)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Triangle « lecture » aux coins adoucis.
struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corner = min(rect.width, rect.height) * 0.12
        let a = CGPoint(x: rect.minX, y: rect.minY)
        let b = CGPoint(x: rect.minX, y: rect.maxY)
        let c = CGPoint(x: rect.maxX, y: rect.midY)
        path.move(to: CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2))
        path.addArc(tangent1End: a, tangent2End: b, radius: corner)
        path.addArc(tangent1End: b, tangent2End: c, radius: corner)
        path.addArc(tangent1End: c, tangent2End: a, radius: corner)
        path.closeSubpath()
        return path
    }
}
