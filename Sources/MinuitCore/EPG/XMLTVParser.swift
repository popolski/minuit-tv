import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Programme XMLTV brut, rattaché à un identifiant de chaîne XMLTV (`channel="…"`).
public struct XMLTVProgramme: Sendable, Hashable {
    public var channelKey: String
    public var start: Date
    public var end: Date?
    public var title: String
    public var subtitle: String?
    public var summary: String?
    public var category: String?
    public var episode: String?
    public var iconURL: URL?
}

public struct XMLTVChannel: Sendable, Hashable {
    public var key: String
    public var displayNames: [String]
    public var iconURL: URL?
}

public struct XMLTVDocument: Sendable {
    public var channels: [XMLTVChannel]
    public var programmes: [XMLTVProgramme]
    public var skippedProgrammes: Int
}

/// Analyseur XMLTV en flux (SAX) : la mémoire reste proportionnelle aux programmes
/// conservés, pas à la taille du fichier. Les filtres (chaînes utiles, fenêtre
/// temporelle) sont appliqués pendant l'analyse.
public final class XMLTVParser: NSObject, XMLParserDelegate {
    public struct Options: Sendable {
        /// Identifiants XMLTV à conserver (comparaison insensible à la casse). `nil` : tout garder.
        public var channelKeys: Set<String>?
        public var window: DateInterval?
        /// Langue préférée pour titres et descriptions multilingues.
        public var preferredLanguage: String

        public init(channelKeys: Set<String>? = nil, window: DateInterval? = nil, preferredLanguage: String = "fr") {
            self.channelKeys = channelKeys.map { Set($0.map { $0.lowercased() }) }
            self.window = window
            self.preferredLanguage = preferredLanguage
        }
    }

    private let options: Options
    private var channels: [XMLTVChannel] = []
    private var programmes: [XMLTVProgramme] = []
    private var skipped = 0

    // État courant
    private var text = ""
    private var currentChannel: XMLTVChannel?
    private var currentProgramme: XMLTVProgramme?
    private var currentLanguage: String?
    private var titleCandidates: [(lang: String?, text: String)] = []
    private var descCandidates: [(lang: String?, text: String)] = []
    private var skippingProgramme = false

    public init(options: Options = Options()) {
        self.options = options
    }

    public enum ParseError: Error, Sendable, Equatable {
        case malformed(line: Int)
    }

    public static func parse(_ data: Data, options: Options = Options()) throws -> XMLTVDocument {
        let delegate = XMLTVParser(options: options)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        // Un fichier tronqué reste exploitable : on garde ce qui a été lu si des programmes existent.
        if !ok && delegate.programmes.isEmpty && delegate.channels.isEmpty {
            throw ParseError.malformed(line: parser.lineNumber)
        }
        return XMLTVDocument(channels: delegate.channels, programmes: delegate.programmes, skippedProgrammes: delegate.skipped)
    }

    // MARK: XMLParserDelegate

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                       qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        currentLanguage = attributes["lang"]
        switch elementName {
        case "channel":
            if let id = attributes["id"] { currentChannel = XMLTVChannel(key: id, displayNames: [], iconURL: nil) }
        case "programme":
            titleCandidates = []
            descCandidates = []
            guard let key = attributes["channel"], let startText = attributes["start"],
                  let start = XMLTVDate.parse(startText) else {
                skipped += 1
                skippingProgramme = true
                return
            }
            if let keys = options.channelKeys, !keys.contains(key.lowercased()) {
                skippingProgramme = true
                return
            }
            let end = attributes["stop"].flatMap(XMLTVDate.parse)
            if let window = options.window {
                let effectiveEnd = end ?? start.addingTimeInterval(3600)
                if effectiveEnd < window.start || start > window.end {
                    skippingProgramme = true
                    return
                }
            }
            skippingProgramme = false
            currentProgramme = XMLTVProgramme(channelKey: key, start: start, end: end, title: "")
        case "icon":
            if let src = attributes["src"], let url = URL(string: src), src.hasPrefix("http") {
                if currentProgramme != nil { currentProgramme?.iconURL = url }
                else if currentChannel != nil { currentChannel?.iconURL = url }
            }
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !skippingProgramme else { return }
        text += string
    }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !skippingProgramme, let string = String(data: CDATABlock, encoding: .utf8) else { return }
        text += string
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        switch elementName {
        case "display-name":
            if !value.isEmpty { currentChannel?.displayNames.append(value) }
        case "channel":
            if let channel = currentChannel { channels.append(channel) }
            currentChannel = nil
        case "title":
            if currentProgramme != nil, !value.isEmpty { titleCandidates.append((currentLanguage, value)) }
        case "sub-title":
            if currentProgramme != nil, !value.isEmpty, currentProgramme?.subtitle == nil { currentProgramme?.subtitle = value }
        case "desc":
            if currentProgramme != nil, !value.isEmpty { descCandidates.append((currentLanguage, value)) }
        case "category":
            if currentProgramme != nil, !value.isEmpty, currentProgramme?.category == nil { currentProgramme?.category = value }
        case "episode-num":
            if currentProgramme != nil, !value.isEmpty, currentProgramme?.episode == nil { currentProgramme?.episode = value }
        case "programme":
            if !skippingProgramme, var programme = currentProgramme {
                programme.title = pick(titleCandidates) ?? "Sans titre"
                programme.summary = pick(descCandidates)
                programmes.append(programme)
            }
            currentProgramme = nil
            skippingProgramme = false
        default:
            break
        }
    }

    private func pick(_ candidates: [(lang: String?, text: String)]) -> String? {
        let preferred = options.preferredLanguage.lowercased()
        return candidates.first(where: { $0.lang?.lowercased().hasPrefix(preferred) == true })?.text
            ?? candidates.first(where: { $0.lang == nil })?.text
            ?? candidates.first?.text
    }
}

/// Dates XMLTV : `YYYYMMDDhhmmss ±hhmm`, avec précision et fuseau optionnels.
/// Sans fuseau, la norme XMLTV impose UTC.
public enum XMLTVDate {
    public static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        var digits = ""
        var index = text.startIndex
        while index < text.endIndex, text[index].isNumber, digits.count < 14 {
            digits.append(text[index])
            index = text.index(after: index)
        }
        guard digits.count >= 8 else { return nil }
        let padded = digits.padding(toLength: 14, withPad: "0", startingAt: 0)
        func number(_ offset: Int, _ length: Int) -> Int {
            let start = padded.index(padded.startIndex, offsetBy: offset)
            return Int(padded[start..<padded.index(start, offsetBy: length)]) ?? 0
        }
        var components = DateComponents()
        components.year = number(0, 4)
        components.month = number(4, 2)
        components.day = number(6, 2)
        components.hour = number(8, 2)
        components.minute = number(10, 2)
        components.second = number(12, 2)
        guard let month = components.month, (1...12).contains(month),
              let day = components.day, (1...31).contains(day),
              let hour = components.hour, (0...23).contains(hour) else { return nil }

        // Reste éventuel : fractions puis décalage.
        var rest = String(text[index...]).trimmingCharacters(in: .whitespaces)
        while let first = rest.first, first.isNumber || first == "." { rest.removeFirst() }
        rest = rest.trimmingCharacters(in: .whitespaces)

        var offsetSeconds = 0
        if let sign = rest.first, sign == "+" || sign == "-" {
            let offsetDigits = rest.dropFirst().filter(\.isNumber)
            if offsetDigits.count >= 4, let hours = Int(offsetDigits.prefix(2)), let minutes = Int(offsetDigits.dropFirst(2).prefix(2)) {
                offsetSeconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
            } else if offsetDigits.count >= 1, let hours = Int(offsetDigits.prefix(2)) {
                offsetSeconds = hours * 3600 * (sign == "-" ? -1 : 1)
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let utcWall = calendar.date(from: components) else { return nil }
        return utcWall.addingTimeInterval(TimeInterval(-offsetSeconds))
    }
}
