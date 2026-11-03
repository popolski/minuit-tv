import SwiftUI
import UIKit
import MinuitCore

/// Logo prêt à l'affichage : image décodée et style de tuile calculé une seule fois.
struct PreparedLogo {
    let image: UIImage
    let tile: LogoTile.Style
}

/// Cache des logos : mémoire (NSCache) + cache HTTP disque (URLCache, dans Caches).
/// Les logos sont publics (aucun identifiant dans leurs URL).
final class LogoCache: @unchecked Sendable {
    static let shared = LogoCache()

    private final class Box {
        let value: PreparedLogo
        init(_ value: PreparedLogo) { self.value = value }
    }

    private let memory = NSCache<NSURL, Box>()
    private let session: URLSession
    private var inflight: [URL: Task<PreparedLogo?, Never>] = [:]
    private let lock = NSLock()

    private init() {
        memory.countLimit = 800
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 80 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 10
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }

    func cached(_ url: URL) -> PreparedLogo? { memory.object(forKey: url as NSURL)?.value }

    func logo(for url: URL) async -> PreparedLogo? {
        if let logo = cached(url) { return logo }
        let task: Task<PreparedLogo?, Never> = lock.withLock {
            if let existing = inflight[url] { return existing }
            let task = Task<PreparedLogo?, Never>.detached(priority: .utility) { [session] in
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      let image = UIImage(data: data) else { return nil }
                let prepared = image.preparingForDisplay() ?? image
                return PreparedLogo(image: prepared, tile: LogoAnalyzer.tileStyle(of: prepared))
            }
            inflight[url] = task
            return task
        }
        let logo = await task.value
        lock.withLock { inflight[url] = nil }
        if let logo { memory.setObject(Box(logo), forKey: url as NSURL) }
        return logo
    }
}

/// Analyse des pixels d'un logo (réduit à 32×32) pour choisir la couleur de sa tuile.
enum LogoAnalyzer {
    static func tileStyle(of image: UIImage) -> LogoTile.Style {
        guard let cgImage = image.cgImage else { return .light }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return .light }

        func rgba(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let i = (y * side + x) * 4
            let a = Double(pixels[i + 3]) / 255
            guard a > 0 else { return (0, 0, 0, 0) }
            // Dé-prémultiplication.
            return (Double(pixels[i]) / 255 / a, Double(pixels[i + 1]) / 255 / a, Double(pixels[i + 2]) / 255 / a, a)
        }

        var edge: [(r: Double, g: Double, b: Double)] = []
        var edgeTotal = 0
        var contentLum = 0.0
        var contentCount = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let p = rgba(x, y)
                if p.a > 0.5 {
                    contentLum += (0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b)
                    contentCount += 1
                }
                if x == 0 || y == 0 || x == side - 1 || y == side - 1 {
                    edgeTotal += 1
                    if p.a > 0.9 { edge.append((p.r, p.g, p.b)) }
                }
            }
        }
        let count = Double(max(1, edge.count))
        let mean = LogoTile.RGB(r: edge.map(\.r).reduce(0, +) / count,
                                g: edge.map(\.g).reduce(0, +) / count,
                                b: edge.map(\.b).reduce(0, +) / count)
        let variance = edge.map { abs($0.r - mean.r) + abs($0.g - mean.g) + abs($0.b - mean.b) }.reduce(0, +) / count / 3
        let stats = LogoTile.Statistics(edgeOpacity: Double(edge.count) / Double(max(1, edgeTotal)),
                                        edgeColor: mean, edgeVariance: variance,
                                        contentLuminance: contentCount > 0 ? contentLum / contentCount : 0.5)
        return LogoTile.style(for: stats)
    }
}

extension LogoTile.Style {
    var background: Color {
        switch self {
        case .solid(let c): return Color(red: c.r, green: c.g, blue: c.b)
        case .dark: return Color(red: 0.11, green: 0.15, blue: 0.25)
        case .light: return Color(red: 0.96, green: 0.97, blue: 0.99)
        }
    }

    /// Couleur d'ambiance (halo de fond) associée au logo.
    var glow: Color {
        switch self {
        case .solid(let c): return Color(red: c.r, green: c.g, blue: c.b)
        case .dark, .light: return Theme.Palette.moon
        }
    }
}

/// Tuile de logo de chaîne : fond prolongeant le logo, repli typographique (initiales).
struct ChannelLogoView: View {
    let channel: Channel
    var size: CGSize = Theme.Metrics.logoSize
    var onLoaded: ((PreparedLogo) -> Void)? = nil

    @State private var logo: PreparedLogo?
    @Environment(\.onFocusPill) private var onPill

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.height * 0.2, style: .continuous)
                .fill(logo?.tile.background ?? (onPill ? Theme.Palette.onFocus.opacity(0.08) : Color.white.opacity(0.1)))
            if let logo {
                Image(uiImage: logo.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(.horizontal, size.width * 0.12)
                    .padding(.vertical, size.height * 0.14)
            } else {
                Text(initials)
                    .font(.system(size: size.height * 0.34, weight: .bold))
                    .foregroundStyle(onPill ? Theme.Palette.onFocusSecondary : Theme.Palette.textSecondary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(6)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: size.height * 0.2, style: .continuous))
        .task(id: channel.logoURL) {
            guard let url = channel.logoURL else { logo = nil; return }
            if let cached = LogoCache.shared.cached(url) { logo = cached; onLoaded?(cached); return }
            if let loaded = await LogoCache.shared.logo(for: url) {
                logo = loaded
                onLoaded?(loaded)
            }
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        let name = SearchNormalizer.stripProviderPrefix(channel.name)
        let words = name.split(separator: " ").prefix(2)
        let text = words.compactMap { $0.first.map(String.init) }.joined()
        return text.isEmpty ? "•" : text.uppercased()
    }
}
