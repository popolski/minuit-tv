import SwiftUI
import UIKit
import MinuitCore

@main
struct MinuitApp: App {
    @State private var app = AppModel()
    @State private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CrashReporter.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(router)
                .preferredColorScheme(.dark)
                .task {
                    await app.start()
                    if case .ready = app.phase, let channel = app.resumeChannel {
                        router.watch(channel.id, context: app.preferences.lastCategory.map { .category($0) } ?? .all, app: app)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Veille ou changement d'application : on libère la connexion et le décodeur.
                app.playback.suspend()
            case .active:
                if router.isPlayerPresented { app.playback.resume() }
                if case .ready = app.phase { app.epg.refreshFullIfNeeded() }
            default:
                break
            }
        }
    }
}

/// Navigation globale : présentation du lecteur plein écran.
@MainActor
@Observable
final class AppRouter {
    var isPlayerPresented = false
    var selectedTab: Tab = .live
    /// Couleur d'ambiance du fond (halo), suit la chaîne focalisée.
    var ambient: Color = Theme.Palette.moon
    /// Image d'ambiance (logo ou image du programme focalisé), très floutée en fond.
    var ambientImage: UIImage?
    /// Section affichée dans l'écran Direct (mémorisée entre les onglets) ; nil : choix initial.
    var liveSection: LiveSection?

    enum LiveSection: Hashable {
        case onAir
        case list(ChannelListContext)
    }

    enum Tab: Hashable { case search, live, guide, settings }

    func watch(_ channel: ChannelID, context: ChannelListContext, app: AppModel) {
        var list = app.channels(in: context).map(\.id)
        if !list.contains(channel) { list = app.channels(in: .all).map(\.id) }
        app.playback.setZapList(list, context: context)
        app.playback.playLive(channel)
        isPlayerPresented = true
    }

    func watchArchive(_ programme: Programme, app: AppModel) {
        app.playback.setZapList(app.channels(in: .all).map(\.id), context: .all)
        isPlayerPresented = true
        Task { await app.playback.playArchive(programme: programme) }
    }
}
