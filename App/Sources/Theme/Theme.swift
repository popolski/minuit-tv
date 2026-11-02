import SwiftUI

/// Direction artistique « Minuit » : nuit bleue profonde, lumière lunaire pour le focus,
/// braise pour le direct. Titres de programmes en serif (New York) pour une lecture
/// éditoriale ; interface et horaires en SF Pro à chiffres tabulaires.
enum Theme {
    enum Palette {
        static let night = Color(red: 0.027, green: 0.043, blue: 0.086)        // #070B16
        static let nightRaised = Color(red: 0.043, green: 0.078, blue: 0.149)  // #0B1426
        static let surface = Color(red: 0.067, green: 0.110, blue: 0.200)      // #111C33
        static let surfaceFocused = Color(red: 0.094, green: 0.149, blue: 0.290) // #18264A
        static let stroke = Color.white.opacity(0.08)

        static let textPrimary = Color(red: 0.933, green: 0.949, blue: 0.980)  // #EEF2FA
        static let textSecondary = Color(red: 0.604, green: 0.659, blue: 0.780) // #9AA8C7
        static let textTertiary = Color(red: 0.373, green: 0.431, blue: 0.561)  // #5F6E8F

        /// Lumière lunaire : focus, sélection.
        static let moon = Color(red: 0.561, green: 0.722, blue: 1.0)            // #8FB8FF
        /// Braise : direct, ligne « maintenant », progression.
        static let ember = Color(red: 1.0, green: 0.541, blue: 0.357)           // #FF8A5B
        /// Archive / replay.
        static let archive = Color(red: 0.706, green: 0.612, blue: 1.0)         // #B49CFF
        static let danger = Color(red: 1.0, green: 0.431, blue: 0.431)

        static let backdrop = LinearGradient(colors: [night, nightRaised], startPoint: .top, endPoint: .bottom)
        /// Voile pour lisibilité au-dessus de la vidéo.
        static let scrimBottom = LinearGradient(colors: [night.opacity(0), night.opacity(0.92)], startPoint: .top, endPoint: .bottom)
        static let scrimLeading = LinearGradient(colors: [night.opacity(0.96), night.opacity(0.0)], startPoint: .leading, endPoint: .trailing)
    }

    enum Typeface {
        static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
        static func title(_ size: CGFloat = 38) -> Font { .system(size: size, weight: .semibold, design: .serif) }
        static func body(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .regular) }
        static func label(_ size: CGFloat = 24) -> Font { .system(size: size, weight: .medium) }
        static func caption(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .medium) }
        static func time(_ size: CGFloat = 24) -> Font { .system(size: size, weight: .medium).monospacedDigit() }
    }

    enum Metrics {
        /// Marges de sécurité TV (overscan) : 60 pt horizontal, 40 pt vertical recommandés.
        static let safeHorizontal: CGFloat = 80
        static let safeVertical: CGFloat = 50
        static let corner: CGFloat = 18
        static let cornerSmall: CGFloat = 12
        static let logoSize = CGSize(width: 120, height: 72)
    }

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.18)
        static let standard = Animation.easeInOut(duration: 0.28)
        static let panel = Animation.spring(response: 0.38, dampingFraction: 0.88)
    }
}

/// Carte focalisable cohérente dans toute l'application : légère élévation et
/// liseré lunaire au focus, sans effet parallaxe excessif.
struct MinuitCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Theme.Metrics.corner

    func makeBody(configuration: Configuration) -> some View {
        MinuitCardBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct MinuitCardBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isFocused ? Theme.Palette.surfaceFocused : Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(isFocused ? Theme.Palette.moon.opacity(0.9) : Theme.Palette.stroke, lineWidth: isFocused ? 3 : 1)
                )
                .shadow(color: isFocused ? Theme.Palette.moon.opacity(0.28) : .clear, radius: 24, y: 10)
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.04 : 1.0))
                .animation(Theme.Motion.quick, value: isFocused)
                .animation(Theme.Motion.quick, value: configuration.isPressed)
        }
    }
}

/// Ligne de liste focalisable (panneaux, réglages).
struct MinuitRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.cornerSmall, style: .continuous)
                        .fill(isFocused ? Theme.Palette.surfaceFocused : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.cornerSmall, style: .continuous)
                        .strokeBorder(isFocused ? Theme.Palette.moon.opacity(0.8) : .clear, lineWidth: 2)
                )
                .foregroundStyle(Theme.Palette.textPrimary)
                .scaleEffect(isFocused ? 1.01 : 1)
                .animation(Theme.Motion.quick, value: isFocused)
        }
    }
}

/// Fine barre de progression « braise ».
struct ProgressLine: View {
    var progress: Double
    var tint: Color = Theme.Palette.ember
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(tint).frame(width: max(height, proxy.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: height)
    }
}

/// Pastille « DIRECT » / « REPLAY ».
struct StatusBadge: View {
    enum Kind { case live, replay, startOver }
    var kind: Kind

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(Theme.Typeface.caption(20)).tracking(1.5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.16)))
        .foregroundStyle(color)
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
        case .replay, .startOver: return Theme.Palette.archive
        }
    }
}

extension Date {
    /// « 20:45 » dans le fuseau de l'appareil.
    var clockText: String {
        formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}
