import SwiftUI
import UIKit
import MinuitCore

/// Écran « Direct » :
/// - barre latérale : À l'antenne, Toutes les chaînes, Favoris, Récentes, catégories ;
/// - « À l'antenne » : grandes cartes des programmes en cours (favoris, sinon récentes) ;
/// - listes : chaînes au centre, fiche de la chaîne focalisée à droite avec **aperçu vidéo
///   en direct** (muet). Le clic passe en plein écran sans recharger le flux : l'aperçu et
///   le plein écran utilisent le même et unique lecteur.
struct LiveScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    @FocusState private var sidebarFocus: AppRouter.LiveSection?
    @State private var focusedChannel: ChannelID?
    @State private var appearance = 0

    private var section: AppRouter.LiveSection { router.liveSection ?? .list(.all) }

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            LiveSidebar(focused: $sidebarFocus)
                .frame(width: 420)
                .focusSection()
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 2)
                .padding(.vertical, 30)
            switch section {
            case .onAir:
                OnAirGrid(sidebarFocus: $sidebarFocus)
                    .focusSection()
            case .list(let context):
                ChannelListColumn(context: context, sidebarFocus: $sidebarFocus, focusedChannel: $focusedChannel)
                    .focusSection()
                if let id = focusedChannel ?? app.preferences.lastChannel, let channel = app.library.channel(id) {
                    ChannelDetailPanel(channel: channel, context: context)
                        .frame(width: 600)
                        .focusSection()
                } else {
                    Spacer().frame(width: 600)
                }
            }
        }
        .padding(.horizontal, Theme.Metrics.safeHorizontal - 30)
        .onAppear {
            if router.liveSection == nil {
                let hasHistory = !app.preferences.favorites.isEmpty || !app.preferences.recents.isEmpty
                router.liveSection = hasHistory ? .onAir : .list(.all)
            }
            appearance += 1
        }
        .onDisappear { app.playback.stopPreview() }
        .onChange(of: router.liveSection) { _, value in
            if value == .onAir { app.playback.stopPreview() }
        }
        // Aperçu : démarre quand le focus reste une seconde sur une chaîne.
        .task(id: PreviewKey(channel: focusedChannel, appearance: appearance)) {
            guard let id = focusedChannel, case .list = section else { return }
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled, !router.isPlayerPresented else { return }
            app.playback.startPreview(id)
        }
        .onChange(of: focusedChannel) { _, id in updateAmbient(for: id) }
    }

    private struct PreviewKey: Hashable {
        let channel: ChannelID?
        let appearance: Int
    }

    private func updateAmbient(for id: ChannelID?) {
        guard let id, let channel = app.library.channel(id) else { return }
        let current = app.epg.nowNext(id).now
        let programmeImage = current?.imageURL.flatMap { LogoCache.shared.cached($0)?.image }
        let logo = channel.logoURL.flatMap { LogoCache.shared.cached($0) }
        router.ambient = logo?.tile.glow ?? Theme.Palette.moon
        router.ambientImage = programmeImage ?? logo?.image
    }
}

// MARK: - Barre latérale

private struct LiveSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(\.backToTopBar) private var backToTopBar
    var focused: FocusState<AppRouter.LiveSection?>.Binding

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                item(.onAir, title: "À l'antenne", icon: "sparkles.tv")
                item(.list(.all), title: "Toutes les chaînes", icon: "square.stack")
                item(.list(.favorites), title: "Favoris", icon: "star")
                item(.list(.recents), title: "Récentes", icon: "clock.arrow.circlepath")
                Text("Catégories").sectionHeader()
                    .padding(.leading, 22)
                    .padding(.top, 24)
                    .padding(.bottom, 6)
                ForEach(app.library.visibleCategories(preferences: app.preferences)) { category in
                    item(.list(.category(category.id)), title: category.name, icon: CategoryIcon.symbol(for: category.name))
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 12)
        }
        .defaultFocus(focused, router.liveSection ?? .list(.all))
        .onExitCommand { backToTopBar() }
        .onChange(of: focused.wrappedValue) { _, value in
            // La partie droite suit le focus, comme dans les réglages tvOS.
            if let value, value != router.liveSection {
                router.liveSection = value
                if case .list(.category(let id)) = value { app.setLastCategory(id) }
            }
        }
    }

    private func item(_ section: AppRouter.LiveSection, title: String, icon: String) -> some View {
        Button { router.liveSection = section } label: {
            HStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 30)
                    .secondaryText()
                Text(title).font(Theme.Typeface.label(25)).lineLimit(1).primaryText()
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(SidebarButtonStyle(isSelected: router.liveSection == section))
        .focused(focused, equals: section)
        .accessibilityIdentifier("sidebar-\(title)")
    }
}

// MARK: - Liste des chaînes

private struct ChannelListColumn: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    let context: ChannelListContext
    var sidebarFocus: FocusState<AppRouter.LiveSection?>.Binding
    @Binding var focusedChannel: ChannelID?
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
                                ChannelRowContent(channel: channel, logoSize: CGSize(width: 128, height: 72), showsTime: false)
                            }
                            .buttonStyle(GlassRowButtonStyle(horizontalPadding: 12, verticalPadding: 9))
                            .focused($focused, equals: channel.id)
                            .accessibilityIdentifier("channel-\(channel.id.rawValue)")
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
            }
        }
        .padding(.top, 20)
        .defaultFocus($focused, app.preferences.lastChannel)
        // Retour : de la liste des chaînes vers la section, à gauche (pas de sortie de l'app).
        .onExitCommand { sidebarFocus.wrappedValue = .list(context) }
        .onChange(of: focused) { _, id in
            if let id { focusedChannel = id }
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
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }
}

// MARK: - Fiche de la chaîne (avec aperçu)

private struct ChannelDetailPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    let channel: Channel
    let context: ChannelListContext

    var body: some View {
        let variants = app.library.variants(of: channel.id)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let upcoming = app.epg.programmes(channel.id, in: DateInterval(start: now, end: now.addingTimeInterval(8 * 3600)))
            let current = upcoming.first { $0.isAiring(at: now) }
            let next = Array(upcoming.filter { $0.start >= now }.prefix(3))
            VStack(alignment: .leading, spacing: 18) {
                PreviewBox(channel: channel, programme: current)
                HStack(spacing: 14) {
                    if let number = channel.number {
                        Text("\(number)").font(Theme.Typeface.time(24)).foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Text(channel.name).font(Theme.Typeface.label(28)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                    if let quality = QualityBadge.parse(channel.name) { MetaTag(text: quality.rawValue) }
                    if channel.hasAnnouncedArchive { MetaTag(text: "Replay", systemImage: "clock.arrow.circlepath") }
                }
                if !variants.isEmpty {
                    // Une seule ligne par chaîne dans la liste : les autres versions se choisissent ici.
                    HStack(spacing: 10) {
                        Text("Versions").font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textSecondary)
                        ForEach(variants) { variant in
                            Button { router.watch(variant.id, context: context, app: app) } label: {
                                Text(PlaybackController.qualityLabel(variant) + (variant.id == channel.id ? " · par défaut" : ""))
                                    .font(Theme.Typeface.label(20)).primaryText()
                            }
                            .buttonStyle(GlassRowButtonStyle(cornerRadius: 22, horizontalPadding: 18, verticalPadding: 8))
                            .fixedSize()
                        }
                    }
                }
                if let current {
                    Text(current.title).font(Theme.Typeface.programme(36)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(2)
                    HStack(spacing: 14) {
                        Text(current.start.clockText).font(Theme.Typeface.time(21))
                        ProgressLine(progress: current.progress(at: now), height: 4)
                        Text(current.end.clockText).font(Theme.Typeface.time(21))
                    }
                    .foregroundStyle(Theme.Palette.textSecondary)
                    if let summary = current.summary {
                        Text(summary).font(Theme.Typeface.body(22)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(4)
                    }
                } else {
                    Text("Programme non communiqué").font(Theme.Typeface.programme(30)).foregroundStyle(Theme.Palette.textTertiary)
                }
                if !next.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ensuite").sectionHeader()
                        ForEach(next) { programme in
                            HStack(spacing: 14) {
                                Text(programme.start.clockText).font(Theme.Typeface.time(21)).foregroundStyle(Theme.Palette.textTertiary)
                                Text(programme.title).font(Theme.Typeface.body(22)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
                Text(variants.isEmpty ? "OK : plein écran · Maintenir OK : favoris"
                                      : "OK : plein écran · Maintenir OK : favoris · ▶ : autres versions")
                    .font(Theme.Typeface.caption(19)).foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.bottom, 24)
            }
            .padding(.top, 70)
        }
        .onAppear { app.epg.ensureFresh([channel.id]) }
    }
}

/// Cadre d'aperçu 16:9 : vidéo en direct (muette) quand l'aperçu concerne cette chaîne,
/// sinon image du programme ou tuile du logo.
private struct PreviewBox: View {
    @Environment(AppModel.self) private var app
    let channel: Channel
    let programme: Programme?

    var body: some View {
        let controller = app.playback
        let previewing = controller.isPreview && controller.displayedChannel == channel.id
        ZStack {
            ArtworkView(channel: channel, programme: programme)
            if previewing {
                PreviewHost(controller: controller)
                    .opacity(controller.phase == .playing ? 1 : 0)
                    .animation(Theme.Motion.standard, value: controller.phase == .playing)
                switch controller.phase {
                case .tuning, .recovering:
                    ProgressView().tint(Theme.Palette.textPrimary)
                case .failed:
                    Label("Aperçu indisponible", systemImage: "eye.slash")
                        .font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                default:
                    EmptyView()
                }
            }
            VStack {
                HStack {
                    StatusBadge(kind: .live)
                    Spacer()
                    if previewing && controller.phase == .playing {
                        Image(systemName: "speaker.slash.fill").font(.system(size: 18))
                            .foregroundStyle(.white).padding(8).background(Circle().fill(Color.black.opacity(0.4)))
                    }
                }
                Spacer()
                HStack {
                    Spacer()
                    Label("Clic central : plein écran", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(Theme.Typeface.caption(17)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                }
            }
            .padding(14)
        }
        .frame(width: 600, height: 338)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    }
}

/// Image d'un programme (guide XMLTV) ou, à défaut, tuile colorée avec le logo.
struct ArtworkView: View {
    let channel: Channel
    let programme: Programme?
    @State private var artwork: UIImage?
    @State private var tile: LogoTile.Style?

    var body: some View {
        ZStack {
            LinearGradient(colors: [(tile?.background ?? Theme.Palette.surfaceFocused).opacity(0.95), Theme.Palette.night],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
            } else {
                ChannelLogoView(channel: channel, size: CGSize(width: 220, height: 124)) { tile = $0.tile }
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            }
        }
        // L'illustration garde ses couleurs, même dans une carte focalisée (fond clair).
        .environment(\.onFocusPill, false)
        .task(id: programme?.imageURL) {
            guard let url = programme?.imageURL else { artwork = nil; return }
            artwork = await LogoCache.shared.logo(for: url)?.image
        }
    }
}

/// Insère la vue de rendu unique du lecteur dans l'aperçu.
private struct PreviewHost: UIViewRepresentable {
    let controller: PlaybackController

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.controller = controller
        view.backgroundColor = .black
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: PreviewContainerView, context: Context) {
        view.controller = controller
        view.adoptHostIfNeeded()
    }
}

final class PreviewContainerView: UIView {
    weak var controller: PlaybackController?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        adoptHostIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        adoptHostIfNeeded()
    }

    /// Ne prend la vue de rendu que pendant l'aperçu : en plein écran, le lecteur la garde.
    func adoptHostIfNeeded() {
        guard window != nil, let controller, controller.isPreview else { return }
        let host = controller.hostView
        if host.superview !== self {
            host.removeFromSuperview()
            addSubview(host)
        }
        host.frame = bounds
    }
}

// MARK: - À l'antenne

private struct OnAirGrid: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    var sidebarFocus: FocusState<AppRouter.LiveSection?>.Binding

    private let columns = Array(repeating: GridItem(.fixed(410), spacing: 34), count: 3)

    var body: some View {
        let (channels, context, subtitle) = selection
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("À l'antenne").font(Theme.Typeface.label(26)).foregroundStyle(Theme.Palette.textSecondary)
                Text(subtitle).font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, 12)
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
                    ForEach(channels) { channel in
                        Button { router.watch(channel.id, context: context, app: app) } label: {
                            OnAirCard(channel: channel)
                        }
                        .buttonStyle(GlassRowButtonStyle(cornerRadius: 22, horizontalPadding: 0, verticalPadding: 0))
                        .accessibilityIdentifier("onair-\(channel.id.rawValue)")
                        .onAppear { app.epg.ensureFresh([channel.id]) }
                    }
                }
                .padding(16)
            }
        }
        .padding(.top, 20)
        .onExitCommand { sidebarFocus.wrappedValue = .onAir }
    }

    /// Favoris d'abord, puis chaînes récentes, complétés par le reste du catalogue
    /// jusqu'à 9 cartes au minimum (une grille presque vide paraît inachevée).
    private var selection: ([Channel], ChannelListContext, String) {
        let favorites = app.channels(in: .favorites)
        let recents = app.channels(in: .recents)
        var result: [Channel] = []
        var seen = Set<ChannelID>()
        for channel in favorites + recents where seen.insert(channel.id).inserted { result.append(channel) }
        let personal = result.count
        if result.count < 9 {
            for channel in app.channels(in: .all) where result.count < 9 && seen.insert(channel.id).inserted {
                result.append(channel)
            }
        }
        let subtitle: String
        switch (favorites.isEmpty, personal) {
        case (false, _): subtitle = "vos favoris d'abord"
        case (true, 1...): subtitle = "vos chaînes récentes d'abord · ajoutez des favoris pour personnaliser"
        default: subtitle = "ajoutez des favoris pour personnaliser"
        }
        return (Array(result.prefix(30)), favorites.isEmpty ? .all : .favorites, subtitle)
    }
}

private struct OnAirCard: View {
    @Environment(AppModel.self) private var app
    let channel: Channel

    var body: some View {
        let (current, next) = app.epg.nowNext(channel.id)
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(channel: channel, programme: current)
                    .frame(width: 410, height: 210)
                    .clipped()
                LinearGradient(colors: [.clear, Color.black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                HStack(spacing: 10) {
                    Circle().fill(Theme.Palette.ember).frame(width: 10, height: 10)
                    Text(channel.name).font(Theme.Typeface.caption(20).weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                }
                .padding(14)
            }
            .frame(width: 410, height: 210)
            VStack(alignment: .leading, spacing: 8) {
                Text(current?.title ?? "Programme non communiqué")
                    .font(Theme.Typeface.programme(24)).lineLimit(1).primaryText()
                if let current {
                    ProgressLine(progress: current.progress(at: Date()), height: 3)
                }
                Text(next.map { "Ensuite \($0.start.clockText) · \($0.title)" } ?? " ")
                    .font(Theme.Typeface.caption(19)).lineLimit(1).tertiaryText()
            }
            .padding(16)
        }
        .frame(width: 410)
    }
}

/// Contenu d'une rangée de chaîne (liste Direct, recherche, mini-guide du lecteur).
struct ChannelRowContent: View {
    @Environment(AppModel.self) private var app
    let channel: Channel
    var isCurrent = false
    var logoSize: CGSize = Theme.Metrics.rowLogo
    var showsTime = true

    var body: some View {
        let (current, _) = app.epg.nowNext(channel.id)
        let quality = QualityBadge.parse(channel.name)
        HStack(spacing: 22) {
            ChannelLogoView(channel: channel, size: logoSize)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    Text(channel.name).font(Theme.Typeface.label(26)).lineLimit(1).primaryText()
                    if app.isFavorite(channel.id) {
                        Image(systemName: "star.fill").font(.system(size: 17)).foregroundStyle(Theme.Palette.moon)
                    }
                    if isCurrent {
                        Circle().fill(Theme.Palette.ember).frame(width: 10, height: 10)
                    }
                }
                HStack(spacing: 10) {
                    if let current {
                        Text(current.title).font(Theme.Typeface.body(21)).lineLimit(1).secondaryText()
                    } else if let category = channel.categoryIDs.first.flatMap({ id in app.library.categories.first { $0.id == id } }) {
                        Text(category.name).font(Theme.Typeface.body(21)).lineLimit(1).tertiaryText()
                    }
                    if let quality { MetaTag(text: quality.rawValue) }
                    if channel.hasAnnouncedArchive { MetaTag(text: "Replay", systemImage: "clock.arrow.circlepath") }
                }
                if let current {
                    ProgressLine(progress: current.progress(at: Date()), height: 3).frame(width: 240)
                }
            }
            Spacer(minLength: 0)
            if showsTime, let current {
                Text("\(current.start.clockText) – \(current.end.clockText)")
                    .font(Theme.Typeface.time(21)).tertiaryText()
            }
        }
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
            (["enfant", "kids", "jeunesse", "cartoon", "junior"], "sparkles"),
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

// MARK: - Recherche

struct SearchScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(\.backToTopBar) private var backToTopBar
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
            .onExitCommand { backToTopBar() }
            .searchable(text: $query, prompt: "Rechercher une chaîne")
        }
    }
}
