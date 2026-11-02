import SwiftUI
import UIKit
import MinuitCore

/// Cache d'images de logos : mémoire (NSCache) + cache HTTP disque (URLCache, dans Caches).
/// Les logos sont publics (pas d'identifiants dans leurs URL).
final class LogoCache: @unchecked Sendable {
    static let shared = LogoCache()

    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private var inflight: [URL: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    private init() {
        memory.countLimit = 600
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 80 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 10
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    func image(for url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let existing = inflight[url] { return existing }
            let task = Task<UIImage?, Never> { [session] in
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      let image = UIImage(data: data) else { return nil }
                // Décodage hors du fil principal pour un défilement fluide.
                return image.preparingForDisplay() ?? image
            }
            inflight[url] = task
            return task
        }
        let image = await task.value
        lock.withLock { inflight[url] = nil }
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// Logo de chaîne, avec repli typographique élégant (initiales) si absent ou invalide.
struct ChannelLogoView: View {
    let channel: Channel
    var size: CGSize = Theme.Metrics.logoSize

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(8)
            } else {
                Text(initials)
                    .font(.system(size: size.height * 0.36, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(6)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: channel.logoURL) {
            guard let url = channel.logoURL else { image = nil; return }
            if let cached = LogoCache.shared.cached(url) { image = cached; return }
            image = await LogoCache.shared.image(for: url)
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
