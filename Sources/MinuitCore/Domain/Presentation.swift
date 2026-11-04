import Foundation

/// Salutation selon l'heure locale (« Bonjour », « Bon après-midi », « Bonsoir », « Bonne nuit »).
public enum Greeting {
    public static func text(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch calendar.component(.hour, from: date) {
        case 5..<12: return "Bonjour"
        case 12..<18: return "Bon après-midi"
        case 18..<23: return "Bonsoir"
        default: return "Bonne nuit"
        }
    }
}

/// Qualité annoncée par le nom de la chaîne (« TF1 FHD », « Canal+ 4K », « M6 ᴴᴰ »).
/// Indication seulement : la résolution réelle n'est connue qu'à la lecture.
public enum QualityBadge: String, Sendable, Hashable, CaseIterable {
    case uhd = "4K"
    case fhd = "FHD"
    case hd = "HD"
    case sd = "SD"

    /// Exposants Unicode utilisés par certains fournisseurs (ᴴᴰ, ᵁᴴᴰ, ᶠᴴᴰ), en lettres.
    static func expandingSuperscripts(_ name: String) -> String {
        var text = name
        for (from, to) in [("ᵁᴴᴰ", " UHD"), ("ᶠᴴᴰ", " FHD"), ("ᴴᴰ", " HD"), ("ˢᴰ", " SD")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text
    }

    public static func parse(_ channelName: String) -> QualityBadge? {
        let tokens = expandingSuperscripts(channelName).uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" })
            .map(String.init)
        let set = Set(tokens)
        if set.contains("4K") || set.contains("UHD") || set.contains("2160P") || set.contains("2160") { return .uhd }
        if set.contains("FHD") || set.contains("1080P") || set.contains("1080") || set.contains("1080I") { return .fhd }
        if set.contains("HD") || set.contains("720P") || set.contains("720") { return .hd }
        if set.contains("SD") || set.contains("576P") || set.contains("480P") { return .sd }
        return nil
    }
}

/// Style de la tuile d'un logo de chaîne, déduit de statistiques de pixels.
///
/// Principe : la tuile reprend la couleur de fond du logo quand il en a une (bords opaques
/// et homogènes) ; pour un logo détouré, la tuile contraste avec le contenu du logo
/// (logo clair → tuile sombre, logo sombre → tuile claire).
public enum LogoTile {
    public struct RGB: Equatable, Sendable {
        public var r: Double
        public var g: Double
        public var b: Double
        public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

        /// Luminance relative (0…1), pondération Rec. 709.
        public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    }

    public struct Statistics: Sendable {
        /// Part des pixels du bord qui sont opaques (0…1).
        public var edgeOpacity: Double
        /// Couleur moyenne des pixels opaques du bord.
        public var edgeColor: RGB
        /// Écart moyen des pixels de bord à leur moyenne (0 = uni).
        public var edgeVariance: Double
        /// Luminance moyenne des pixels opaques de tout le logo.
        public var contentLuminance: Double

        public init(edgeOpacity: Double, edgeColor: RGB, edgeVariance: Double, contentLuminance: Double) {
            self.edgeOpacity = edgeOpacity
            self.edgeColor = edgeColor
            self.edgeVariance = edgeVariance
            self.contentLuminance = contentLuminance
        }
    }

    public enum Style: Equatable, Sendable {
        /// Fond du logo prolongé dans la tuile.
        case solid(RGB)
        /// Logo détouré clair : tuile sombre.
        case dark
        /// Logo détouré sombre : tuile claire.
        case light
    }

    public static func style(for stats: Statistics) -> Style {
        if stats.edgeOpacity >= 0.85 && stats.edgeVariance <= 0.08 {
            return .solid(stats.edgeColor)
        }
        return stats.contentLuminance >= 0.6 ? .dark : .light
    }
}
