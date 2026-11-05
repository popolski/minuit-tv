import SwiftUI
import UIKit
import MinuitCore

/// Cache des affiches et fonds : images réduites à leur taille d'affichage (une grille de
/// films en contient des centaines), mémoire bornée en octets, cache HTTP disque.
final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession

    private init() {
        memory.totalCostLimit = 120 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 12
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }

    private func key(_ url: URL, _ maxPixel: CGFloat) -> NSString { "\(url.absoluteString)#\(Int(maxPixel))" as NSString }

    func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? { memory.object(forKey: key(url, maxPixel)) }

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let image = cached(url, maxPixel: maxPixel) { return image }
        let image = await Task.detached(priority: .utility) { [session] () -> UIImage? in
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = UIImage(data: data) else { return nil }
            let scale = min(1, maxPixel / max(image.size.width, image.size.height))
            let target = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
            return image.preparingThumbnail(of: target) ?? image
        }.value
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: key(url, maxPixel), cost: cost)
        }
        return image
    }
}

/// Image distante (affiche, fond), repli dégradé avec icône.
struct RemoteImage: View {
    let url: URL?
    var placeholderIcon = "film"
    /// Plus grand côté en pixels après réduction.
    var maxPixel: CGFloat = 500

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Theme.Palette.surfaceFocused, Theme.Palette.night], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: placeholderIcon).font(.system(size: 44, weight: .light)).foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = ArtworkCache.shared.cached(url, maxPixel: maxPixel) { image = cached; return }
            image = await ArtworkCache.shared.image(for: url, maxPixel: maxPixel)
        }
        .accessibilityHidden(true)
    }
}

/// Carte d'affiche 2:3 : titre dessous, progression ou « vu » s'il y a lieu.
struct PosterCard: View {
    let title: String
    let posterURL: URL?
    var caption: String?
    var progress: Double?
    var finished = false
    var icon = "film"

    static let size = CGSize(width: 232, height: 348)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: posterURL, placeholderIcon: icon)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .clipped()
                if let progress, progress > 0 {
                    ProgressLine(progress: progress, height: 5)
                        .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if finished {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 30))
                        .foregroundStyle(.white, Theme.Palette.moon).padding(10)
                }
            }
            .environment(\.onFocusPill, false)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.Typeface.label(21)).lineLimit(2).primaryText()
                if let caption { Text(caption).font(Theme.Typeface.caption(18)).lineLimit(1).tertiaryText() }
            }
            .frame(width: Self.size.width - 8, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .frame(width: Self.size.width)
    }
}

/// Carte « Continuer à regarder » (accueil) : affiche, titre, épisode, progression.
struct ContinueCard: View {
    let entry: WatchProgress.Entry

    var body: some View {
        HStack(spacing: 18) {
            RemoteImage(url: entry.imageURL, placeholderIcon: entry.kind == .movie ? "film" : "tv")
                .frame(width: 120, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .environment(\.onFocusPill, false)
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.title).font(Theme.Typeface.label(24)).lineLimit(2).primaryText()
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(Theme.Typeface.body(20)).lineLimit(2).secondaryText()
                }
                Spacer(minLength: 0)
                if entry.queued {
                    Text("À suivre").font(Theme.Typeface.caption(18)).foregroundStyle(Theme.Palette.moon)
                } else {
                    ProgressLine(progress: entry.fraction, height: 4)
                    Text(VODFormat.remaining(position: entry.position, duration: entry.duration))
                        .font(Theme.Typeface.caption(18)).tertiaryText()
                }
            }
            .padding(.vertical, 8)
        }
        .padding(14)
        .frame(width: 440, height: 208, alignment: .leading)
    }
}

enum VODFormat {
    /// « Reste 42 min ».
    static func remaining(position: Double, duration: Double) -> String {
        guard duration > 0 else { return "" }
        let minutes = max(1, Int((duration - position) / 60))
        return minutes >= 60 ? "Reste \(minutes / 60) h \(String(format: "%02d", minutes % 60))" : "Reste \(minutes) min"
    }

    /// « 1:02:05 » ou « 12:05 ».
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Ligne d'informations d'une fiche : « 2019 · Drame · 1 h 49 · ★ 7,4 ».
    static func meta(year: Int?, genre: String?, duration: Int?, rating: Double?) -> String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let genre = genre?.split(separator: ",").prefix(2).map({ $0.trimmingCharacters(in: .whitespaces) }).joined(separator: ", "), !genre.isEmpty {
            parts.append(genre)
        }
        if let label = VODText.durationLabel(duration) { parts.append(label) }
        if let rating { parts.append("★ " + String(format: "%.1f", rating).replacingOccurrences(of: ".", with: ",")) }
        return parts.joined(separator: " · ")
    }
}
