import SwiftUI
import MinuitCore

/// Écran « Direct » : barre latérale (listes et catégories) à gauche, chaînes à droite.
/// La liste de droite suit l'élément focalisé à gauche ; le fond prend la couleur
/// du logo de la chaîne focalisée.
struct LiveScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            LiveSidebar()
                .frame(width: 500)
                .focusSection()
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 2)
                .padding(.vertical, 30)
            ChannelListColumn(context: router.liveContext)
                .focusSection()
        }
        .padding(.horizontal, Theme.Metrics.safeHorizontal - 20)
    }
}

// MARK: - Barre latérale

private struct LiveSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    @FocusState private var focused: ChannelListContext?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                item(.all, title: "Toutes les chaînes", icon: "square.stack")
                item(.favorites, title: "Favoris", icon: "star")
                item(.recents, title: "Récentes", icon: "clock.arrow.circlepath")
                Text("Catégories").sectionHeader()
                    .padding(.leading, 22)
                    .padding(.top, 24)
                    .padding(.bottom, 6)
                ForEach(app.library.visibleCategories(preferences: app.preferences)) { category in
                    item(.category(category.id), title: category.name, icon: CategoryIcon.symbol(for: category.name))
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 12)
        }
        .scrollClipDisabled()
        .defaultFocus($focused, router.liveContext)
        .onChange(of: focused) { _, value in
            // La liste de droite suit le focus, comme dans les réglages tvOS.
            if let value, value != router.liveContext {
                router.liveContext = value
                if case .category(let id) = value { app.setLastCategory(id) }
            }
        }
    }

    private func item(_ context: ChannelListContext, title: String, icon: String) -> some View {
        Button { router.liveContext = context } label: {
            HStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 30)
                    .secondaryText()
                Text(title).font(Theme.Typeface.label(25)).lineLimit(1).primaryText()
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(SidebarButtonStyle(isSelected: router.liveContext == context))
        .focused($focused, equals: context)
    }
}

/// Icône évocatrice selon le nom de la catégorie (repli : dossier).
enum CategoryIcon {
    static func symbol(for name: String) -> String {
        let key = SearchNormalizer.normalize(name)
        let table: [(words: [String], symbol: String)] = [
            (["sport", "foot", "soccer", "rugby", "tennis", "f1", "nba", "nfl", "bein", "dazn", "eurosport"], "sportscourt"),
            (["info", "news", "actualite"], "newspaper"),
            (["cinema", "film", "movie", "ciné"], "film"),
            (["serie", "series"], "tv"),
            (["music", "musique", "radio"], "music.note"),
            (["enfant", "kids", "jeunesse", "cartoon", "junior"], "figure.and.child.holdhand"),
            (["docu", "decouverte", "nature", "science", "histoire"], "leaf"),
            (["meteo", "weather"], "cloud.sun"),
            (["cuisine", "food", "cooking"], "fork.knife"),
            (["4k", "uhd"], "sparkles.tv"),
            (["adult", "xxx", "18"], "eye.slash"),
            (["religi"], "building.columns"),
            (["generaliste", "general", "tnt"], "antenna.radiowaves.left.and.right"),
        ]
        for entry in table where entry.words.contains(where: { key.contains($0) }) {
            return entry.symbol
        }
        return "folder"
    }
}

// MARK: - Colonne des chaînes

private struct ChannelListColumn: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    let context: ChannelListContext
    @FocusState private var focused: ChannelID?

    var body: some View {
        let channels = app.channels(in: context)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(title).font(Theme.Typeface.label(26)).foregroundStyle(Theme.Palette.textSecondary)
                Image(systemName: "chevron.right").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                Text("\(channels.count) chaîne\(channels.count > 1 ? "s" : "")")
                    .font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, 12)

            if channels.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(channels) { channel in
                            Button { router.watch(channel.id, context: context, app: app) } label: {
                                ChannelRowContent(channel: channel)
                            }
                            .buttonStyle(GlassRowButtonStyle(horizontalPadding: 14, verticalPadding: 10))
                            .focused($focused, equals: channel.id)
                            .contextMenu {
                                Button(app.isFavorite(channel.id) ? "Retirer des favoris" : "Ajouter aux favoris") {
                                    app.toggleFavorite(channel.id)
                                }
                                if case .favorites = context {
                                    Button("Monter") { app.moveFavorite(channel.id, by: -1) }
                                    Button("Descendre") { app.moveFavorite(channel.id, by: 1) }
                                }
                            }
                            .onAppear { app.epg.ensureFresh([channel.id]) }
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                }
                .scrollClipDisabled()
            }
        }
        .padding(.top, 20)
        .defaultFocus($focused, app.preferences.lastChannel)
        .onChange(of: focused) { _, id in
            guard let id, let url = app.library.channel(id)?.logoURL, let logo = LogoCache.shared.cached(url) else {
                router.ambient = Theme.Palette.moon
                return
            }
            router.ambient = logo.tile.glow
        }
    }

    private var title: String {
        switch context {
        case .all: return "Toutes les chaînes"
        case .favorites: return "Favoris"
        case .recents: return "Récentes"
        case .category(let id): return app.library.categories.first { $0.id == id }?.name ?? "Chaînes"
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: context == .favorites ? "star" : "tv")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.Palette.moon)
            Text(context == .favorites ? "Aucun favori pour l'instant" : "Aucune chaîne ici")
                .font(Theme.Typeface.title(34)).foregroundStyle(Theme.Palette.textPrimary)
            if context == .favorites {
                Text("Pendant la lecture, maintenez le bouton central pour ajouter la chaîne.")
                    .font(Theme.Typeface.body(24)).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }
}

/// Contenu d'une rangée de chaîne (liste Direct, recherche, mini-guide du lecteur).
struct ChannelRowContent: View {
    @Environment(AppModel.self) private var app
    let channel: Channel
    var isCurrent = false
    var logoSize: CGSize = Theme.Metrics.rowLogo

    var body: some View {
        let (current, _) = app.epg.nowNext(channel.id)
        let quality = QualityBadge.parse(channel.name)
        HStack(spacing: 24) {
            ChannelLogoView(channel: channel, size: logoSize)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    Text(channel.name).font(Theme.Typeface.label(27)).lineLimit(1).primaryText()
                    if app.isFavorite(channel.id) {
                        Image(systemName: "star.fill").font(.system(size: 17)).foregroundStyle(Theme.Palette.moon)
                    }
                    if isCurrent {
                        Circle().fill(Theme.Palette.ember).frame(width: 10, height: 10)
                    }
                }
                HStack(spacing: 10) {
                    if let current {
                        Text(current.title).font(Theme.Typeface.body(22)).lineLimit(1).secondaryText()
                    } else if let category = channel.categoryIDs.first.flatMap({ id in app.library.categories.first { $0.id == id } }) {
                        Text(category.name).font(Theme.Typeface.body(22)).lineLimit(1).tertiaryText()
                    }
                    if let quality { MetaTag(text: quality.rawValue) }
                    if channel.hasAnnouncedArchive { MetaTag(text: "Replay", systemImage: "clock.arrow.circlepath") }
                }
                if let current {
                    ProgressLine(progress: current.progress(at: Date()), height: 3).frame(width: 280)
                }
            }
            Spacer(minLength: 0)
            if let current {
                Text("\(current.start.clockText) – \(current.end.clockText)")
                    .font(Theme.Typeface.time(21)).tertiaryText()
            }
        }
    }
}

// MARK: - Recherche

struct SearchScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if query.isEmpty {
                        Text("Nom ou numéro de chaîne").font(Theme.Typeface.body(26))
                            .foregroundStyle(Theme.Palette.textTertiary).padding(.top, 60)
                    }
                    ForEach(app.library.search(query, preferences: app.preferences, limit: 80)) { channel in
                        Button { router.watch(channel.id, context: .all, app: app) } label: {
                            ChannelRowContent(channel: channel)
                        }
                        .buttonStyle(GlassRowButtonStyle(horizontalPadding: 14, verticalPadding: 10))
                        .onAppear { app.epg.ensureFresh([channel.id]) }
                    }
                }
                .padding(.horizontal, Theme.Metrics.safeHorizontal + 160)
                .padding(.vertical, 20)
            }
            .searchable(text: $query, prompt: "Rechercher une chaîne")
        }
    }
}
