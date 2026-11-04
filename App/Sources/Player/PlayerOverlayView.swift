import SwiftUI
import MinuitCore

/// Surcouche du lecteur, style « verre » :
/// - en haut à gauche : tuile du logo, chaîne, métadonnées ; en haut à droite : DIRECT et heure ;
/// - en bas : programme, progression, suivant ; boutons ronds à droite (mode commandes) ;
/// - panneaux latéraux translucides (chaînes, programmes) et menus flottants.
struct PlayerOverlayView: View {
    let app: AppModel
    @Bindable var controller: PlaybackController

    var body: some View {
        ZStack {
            stateLayer
            if controller.isLive && (controller.panel == .controls || (controller.bannerVisible && controller.panel == .none)) {
                LiveChrome(app: app, controller: controller, showsControls: controller.panel == .controls)
                    .transition(.opacity)
            }
            switch controller.panel {
            case .channels:
                ChannelPanel(app: app, controller: controller)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .programmes:
                ProgrammePanel(app: app, controller: controller)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .transport:
                TransportPanel(controller: controller)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .tracks:
                TracksPanel(controller: controller)
                    .transition(.opacity)
            case .none, .controls:
                EmptyView()
            }
            if let toast = controller.toast {
                VStack {
                    Text(toast)
                        .font(Theme.Typeface.label(24))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, 30).padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(.top, Theme.Metrics.safeVertical + 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.panel, value: controller.panel)
        .animation(Theme.Motion.standard, value: controller.bannerVisible)
        .animation(Theme.Motion.standard, value: controller.toast)
    }

    @ViewBuilder private var stateLayer: some View {
        switch controller.phase {
        case .tuning, .resolvingArchive:
            TuningView(title: controller.phase == .resolvingArchive ? "Vérification de l'archive…" : nil,
                       channel: controller.displayedChannel.flatMap { app.library.channel($0) })
        case .recovering(let message):
            TuningView(title: message, channel: controller.displayedChannel.flatMap { app.library.channel($0) })
        case .waitingForNetwork:
            TuningView(title: "En attente du réseau…", channel: nil)
        case .failed(let message):
            FailureView(message: message, controller: controller)
        case .idle, .playing:
            if controller.isBuffering {
                VStack(spacing: 22) {
                    ProgressView().scaleEffect(1.4).tint(Theme.Palette.textPrimary)
                    if controller.isReconnecting {
                        Text("Reconnexion au fournisseur…").font(Theme.Typeface.label(24))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .padding(.horizontal, 22).padding(.vertical, 10)
                            .background(Capsule().fill(Theme.Palette.night.opacity(0.6)))
                    }
                }
            }
        }
    }
}

// MARK: - États

private struct TuningView: View {
    var title: String?
    var channel: Channel?

    var body: some View {
        VStack(spacing: 26) {
            if let channel { ChannelLogoView(channel: channel, size: CGSize(width: 240, height: 134)) }
            ProgressView().tint(Theme.Palette.textPrimary)
            if let title {
                Text(title).font(Theme.Typeface.label(24)).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(48)
    }
}

private struct FailureView: View {
    let message: String
    let controller: PlaybackController

    var body: some View {
        ZStack {
            Theme.Palette.night.opacity(0.8).ignoresSafeArea()
            VStack(spacing: 30) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Theme.Palette.ember)
                Text(message).font(Theme.Typeface.title(38)).multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let detail = controller.failureDetail, !detail.isEmpty {
                    Text(detail).font(.system(size: 19, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .multilineTextAlignment(.center).lineLimit(3)
                }
                HStack(spacing: 24) {
                    Button { controller.retry() } label: {
                        Label("Réessayer", systemImage: "arrow.clockwise").font(Theme.Typeface.label(24)).primaryText()
                    }
                    .buttonStyle(GlassRowButtonStyle(cornerRadius: 40, horizontalPadding: 34, verticalPadding: 16))
                    .fixedSize()
                    Button { controller.panel = .channels } label: {
                        Label("Autres chaînes", systemImage: "list.bullet").font(Theme.Typeface.label(24)).primaryText()
                    }
                    .buttonStyle(GlassRowButtonStyle(cornerRadius: 40, horizontalPadding: 34, verticalPadding: 16))
                    .fixedSize()
                    // « Réseau ou fournisseur ? » : le panneau Informations mesure les trois.
                    Button { controller.panel = .tracks } label: {
                        Label("Tester la connexion", systemImage: "network").font(Theme.Typeface.label(24)).primaryText()
                    }
                    .buttonStyle(GlassRowButtonStyle(cornerRadius: 40, horizontalPadding: 34, verticalPadding: 16))
                    .fixedSize()
                }
            }
            .frame(maxWidth: 1100)
        }
    }
}

// MARK: - Habillage du direct (bandeau + commandes)

private struct LiveChrome: View {
    let app: AppModel
    let controller: PlaybackController
    let showsControls: Bool

    var body: some View {
        // Chaque seconde pendant une pause : le retard sur le direct défile.
        TimelineView(.periodic(from: .now, by: controller.isPaused ? 1 : 15)) { context in
            if let id = controller.displayedChannel, let channel = app.library.channel(id) {
                let delay = controller.liveDelay(at: context.date)
                // Programme à la position regardée (en retard après une pause), pas à l'heure murale.
                let watched = context.date.addingTimeInterval(-delay)
                let (current, next) = app.epg.nowNext(channel.id, at: watched)
                VStack(spacing: 0) {
                    top(channel: channel, current: current, now: context.date, delay: delay)
                    Spacer()
                    bottom(current: current, next: next, now: watched, live: context.date)
                }
                .onAppear { app.epg.ensureFresh([channel.id]) }
            }
        }
        .ignoresSafeArea()
    }

    private func top(channel: Channel, current: Programme?, now: Date, delay: TimeInterval) -> some View {
        HStack(alignment: .top, spacing: 22) {
            ChannelLogoView(channel: channel, size: CGSize(width: 132, height: 74))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    if let number = channel.number {
                        Text("\(number)").font(Theme.Typeface.time(28)).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Text(app.displayName(channel)).font(Theme.Typeface.label(32)).foregroundStyle(Theme.Palette.textPrimary)
                    if app.isFavorite(channel.id) {
                        Image(systemName: "star.fill").font(.system(size: 20)).foregroundStyle(Theme.Palette.moon)
                    }
                }
                Text(metaLine(channel: channel))
                    .font(Theme.Typeface.caption(22)).foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 14) {
                    if controller.isPaused {
                        Label("En pause", systemImage: "pause.fill").font(Theme.Typeface.caption(21))
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }
                    StatusBadge(kind: .live)
                    if let label = LiveDelayClock.label(delay) {
                        // Retard sur le direct, en braise : le temps réel est la référence.
                        Text(label).font(Theme.Typeface.time(28)).foregroundStyle(Theme.Palette.ember)
                    }
                }
                Text(now.clockText).font(Theme.Typeface.time(30)).foregroundStyle(Theme.Palette.textPrimary)
                if !showsControls {
                    Text(remoteHint(delayed: delay >= 1))
                        .font(Theme.Typeface.caption(19)).foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
        .padding(.horizontal, Theme.Metrics.safeHorizontal)
        .padding(.top, Theme.Metrics.safeVertical)
        .padding(.bottom, 60)
        .background(Theme.Palette.scrimTop)
    }

    /// Rappel discret des gestes utiles dans l'état courant.
    private func remoteHint(delayed: Bool) -> String {
        if controller.isPaused { return "Lecture/Pause : reprendre · Retour : revenir au direct" }
        if delayed { return "Retour : revenir au direct · Clic : commandes" }
        return "▲▼ Zapper · ◀ Chaînes · ▶ Programmes · Clic : commandes"
    }

    private func metaLine(channel: Channel) -> String {
        var parts: [String] = []
        if let category = channel.categoryIDs.first.flatMap({ id in app.library.categories.first { $0.id == id } }) {
            parts.append(category.name)
        }
        if let quality = QualityBadge.parse(channel.name) { parts.append(quality.rawValue) }
        if let archive = channel.archive, archive.days > 0 { parts.append("Replay \(archive.days) j") }
        if let attempt = controller.activeAttempt { parts.append(attempt.format == .hls ? "HLS" : "MPEG-TS") }
        return parts.joined(separator: " • ")
    }

    private func bottom(current: Programme?, next: Programme?, now: Date, live: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let current {
                Text(current.title).font(Theme.Typeface.programme(44)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                HStack(alignment: .top, spacing: 18) {
                    Text(current.start.clockText).font(Theme.Typeface.time(22))
                    LiveProgressBar(programme: current, watched: now, live: live)
                    Text(current.end.clockText).font(Theme.Typeface.time(22))
                }
                .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                Text("Programme non communiqué").font(Theme.Typeface.programme(36)).foregroundStyle(Theme.Palette.textSecondary)
            }
            HStack(alignment: .bottom) {
                if let next {
                    Text("Ensuite à \(next.start.clockText) · \(next.title)")
                        .font(Theme.Typeface.body(24)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                }
                Spacer()
                if showsControls {
                    ControlButtons(app: app, controller: controller)
                }
            }
        }
        .padding(.horizontal, Theme.Metrics.safeHorizontal)
        .padding(.bottom, Theme.Metrics.safeVertical)
        .padding(.top, 120)
        .background(Theme.Palette.scrimBottom)
    }
}

/// Progression du programme : partie regardée, partie en mémoire jusqu'au direct (après
/// une pause), repère du direct ; heures « vous » et « direct » sous la barre quand elles diffèrent.
private struct LiveProgressBar: View {
    let programme: Programme
    let watched: Date
    let live: Date

    var body: some View {
        let position = programme.progress(at: watched)
        let edge = programme.progress(at: live)
        let delayed = live.timeIntervalSince(watched) >= 1
        VStack(spacing: 10) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.textPrimary.opacity(0.2))
                    if delayed {
                        Capsule().fill(Theme.Palette.ember.opacity(0.35)).frame(width: width * edge)
                    }
                    Capsule().fill(Theme.Palette.ember).frame(width: width * position)
                    if delayed {
                        Capsule().fill(Theme.Palette.ember).frame(width: 4, height: 18).offset(x: width * edge - 2)
                        Circle().fill(Theme.Palette.textPrimary).frame(width: 18, height: 18).offset(x: width * position - 9)
                    }
                }
                .frame(height: 6)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
            if delayed {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .leading) {
                        Text("\(watched.clockText) vous").font(Theme.Typeface.time(19)).foregroundStyle(Theme.Palette.textPrimary)
                            .fixedSize().offset(x: max(0, width * position - 50))
                        Text("\(live.clockText) direct").font(Theme.Typeface.time(19)).foregroundStyle(Theme.Palette.ember)
                            .fixedSize().offset(x: min(width - 110, max(width * position + 90, width * edge - 20)))
                    }
                }
                .frame(height: 24)
            }
        }
    }
}

/// Boutons ronds du lecteur, avec libellé du bouton focalisé et menu « Plus ».
private struct ControlButtons: View {
    let app: AppModel
    let controller: PlaybackController

    enum Item: Hashable { case channels, programmes, audio, favorite, fill, more }

    @FocusState private var focused: Item?
    @State private var menuOpen = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 14) {
            if menuOpen {
                MoreMenu(controller: controller) { menuOpen = false }
                    .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
            }
            Text(label(for: focused))
                .font(Theme.Typeface.caption(21)).foregroundStyle(Theme.Palette.textPrimary)
                .opacity(focused == nil || menuOpen ? 0 : 1)
            HStack(spacing: 22) {
                button(.channels, "list.bullet") { controller.panel = .channels }
                button(.programmes, "calendar") { controller.panel = .programmes }
                button(.audio, "waveform") { controller.panel = .tracks }
                button(.favorite, isFavorite ? "star.fill" : "star") {
                    guard let id = controller.displayedChannel else { return }
                    app.toggleFavorite(id)
                    controller.showToast(app.isFavorite(id) ? "Ajoutée aux favoris" : "Retirée des favoris")
                }
                button(.fill, controller.fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    controller.toggleFillMode()
                }
                button(.more, "ellipsis") { withAnimation(Theme.Motion.panel) { menuOpen.toggle() } }
            }
            .disabled(menuOpen)
        }
        .defaultFocus($focused, Item.channels)
        .onExitCommand {
            if menuOpen { withAnimation(Theme.Motion.panel) { menuOpen = false } } else { controller.panel = .none }
        }
    }

    private var isFavorite: Bool {
        controller.displayedChannel.map { app.isFavorite($0) } ?? false
    }

    private func label(for item: Item?) -> String {
        switch item {
        case .channels: return "Chaînes"
        case .programmes: return "Programmes et replay"
        case .audio: return "Audio et informations"
        case .favorite: return isFavorite ? "Retirer des favoris" : "Ajouter aux favoris"
        case .fill: return controller.fillsScreen ? "Image ajustée" : "Image plein écran"
        case .more: return "Plus"
        case nil: return " "
        }
    }

    private func button(_ item: Item, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(RoundIconButtonStyle())
            .focused($focused, equals: item)
    }
}

/// Menu flottant « Plus ».
private struct MoreMenu: View {
    let controller: PlaybackController
    let close: () -> Void
    @FocusState private var first: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Recharger la chaîne", "arrow.clockwise") { controller.reloadCurrent() }
                .focused($first)
            row("Chaîne précédente", "arrow.uturn.backward") { controller.recallPreviousChannel() }
            ForEach(controller.otherVariants) { variant in
                row("Version \(PlaybackController.qualityLabel(variant))", "rectangle.stack") { controller.switchVariant(to: variant.id) }
            }
            row("Fermer le menu", "xmark") {}
        }
        .padding(12)
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial))
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.Palette.night.opacity(0.55)))
        .onAppear { first = true }
    }

    private func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            close()
        } label: {
            HStack {
                Text(title).font(Theme.Typeface.label(24)).primaryText()
                Spacer()
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).secondaryText()
            }
        }
        .buttonStyle(GlassRowButtonStyle(horizontalPadding: 22, verticalPadding: 14))
    }
}

// MARK: - Panneau des chaînes (mini-guide)

private struct GlassPanel<Content: View>: View {
    let edge: HorizontalEdge
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            if edge == .trailing { Spacer() }
            content
                .padding(.vertical, Theme.Metrics.safeVertical)
                .padding(.horizontal, 36)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background(.ultraThinMaterial)
                .background(Theme.Palette.night.opacity(0.55))
            if edge == .leading { Spacer() }
        }
        .ignoresSafeArea()
    }
}

private struct ChannelPanel: View {
    let app: AppModel
    let controller: PlaybackController
    @FocusState private var focused: ChannelID?

    var body: some View {
        let channels = app.channels(in: controller.zapContext)
        GlassPanel(edge: .leading, width: 900) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text(title).font(Theme.Typeface.label(28)).foregroundStyle(Theme.Palette.textPrimary)
                    Image(systemName: "chevron.right").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.Palette.textTertiary)
                }
                .padding(.leading, 14)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(channels) { channel in
                                Button { controller.playLive(channel.id); controller.panel = .none } label: {
                                    ChannelRowContent(channel: channel, isCurrent: channel.id == controller.displayedChannel,
                                                      logoSize: CGSize(width: 120, height: 68))
                                }
                                .buttonStyle(GlassRowButtonStyle(horizontalPadding: 12, verticalPadding: 8))
                                .focused($focused, equals: channel.id)
                                .id(channel.id)
                                .onAppear { app.epg.ensureFresh([channel.id]) }
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 10)
                    }
                    .scrollClipDisabled()
                    .defaultFocus($focused, controller.displayedChannel)
                    .onAppear {
                        guard let current = controller.displayedChannel else { return }
                        proxy.scrollTo(current, anchor: .center)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = current }
                    }
                }
            }
        }
        .onExitCommand { controller.panel = .none }
    }

    private var title: String {
        switch controller.zapContext {
        case .favorites: return "Favoris"
        case .recents: return "Récentes"
        case .category(let id): return app.library.categories.first { $0.id == id }?.name ?? "Chaînes"
        case .all: return "Toutes les chaînes"
        }
    }
}

// MARK: - Panneau des programmes (avant / après, replay)

private struct ProgrammePanel: View {
    let app: AppModel
    let controller: PlaybackController
    @FocusState private var focused: String?

    var body: some View {
        GlassPanel(edge: .trailing, width: 940) {
            VStack(alignment: .leading, spacing: 16) {
                if let id = controller.displayedChannel, let channel = app.library.channel(id) {
                    HStack(spacing: 18) {
                        ChannelLogoView(channel: channel, size: CGSize(width: 110, height: 62))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.displayName(channel)).font(Theme.Typeface.label(28)).foregroundStyle(Theme.Palette.textPrimary)
                            Text(channel.hasAnnouncedArchive ? "Replay annoncé sur \(channel.archive?.days ?? 0) jours" : "Pas de replay annoncé")
                                .font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    .padding(.leading, 14)
                    list(for: channel)
                        .task { await app.epg.loadDetailed(channel.id) }
                }
            }
        }
        .onExitCommand { controller.panel = .none }
    }

    private func list(for channel: Channel) -> some View {
        let now = Date()
        let archiveDays = Double(channel.archive?.days ?? 0)
        let interval = DateInterval(start: now.addingTimeInterval(-max(archiveDays, 0.25) * 86_400), end: now.addingTimeInterval(86_400))
        let programmes = app.epg.programmes(channel.id, in: interval)
        let currentID = programmes.first { $0.isAiring(at: now) }?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if programmes.isEmpty {
                        Text("Aucun programme communiqué pour cette chaîne.")
                            .font(Theme.Typeface.body(24)).foregroundStyle(Theme.Palette.textSecondary).padding(24)
                    }
                    ForEach(programmes) { programme in
                        let availability = CatchupEvaluator.evaluate(programme: programme, channel: channel,
                                                                     now: now.addingTimeInterval(app.session?.server.clockSkew ?? 0),
                                                                     settings: app.settings.catchup)
                        Button {
                            if availability.window != nil {
                                Task { await controller.playArchive(programme: programme) }
                            } else {
                                controller.showToast(availability.userLabel)
                            }
                        } label: {
                            ProgrammeRow(programme: programme, availability: availability, now: now)
                        }
                        .buttonStyle(GlassRowButtonStyle(horizontalPadding: 20, verticalPadding: 12))
                        .focused($focused, equals: programme.id)
                        .id(programme.id)
                    }
                }
                .padding(10)
            }
            .scrollClipDisabled()
            .defaultFocus($focused, currentID)
            .onAppear {
                guard let currentID else { return }
                proxy.scrollTo(currentID, anchor: .center)
                // Après la mise en place du panneau, sinon le focus n'est pas appliqué.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = currentID }
            }
        }
    }
}

struct ProgrammeRow: View {
    let programme: Programme
    let availability: CatchupAvailability
    let now: Date

    var body: some View {
        let dimmed = programme.hasEnded(at: now) && availability.window == nil
        HStack(alignment: .center, spacing: 20) {
            Text(programme.start.clockText).font(Theme.Typeface.time(23)).secondaryText()
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(programme.title).font(Theme.Typeface.programme(26)).lineLimit(1)
                    .modifier(DimmableText(dimmed: dimmed))
                if programme.isAiring(at: now) {
                    ProgressLine(progress: programme.progress(at: now), height: 3).frame(width: 300)
                }
            }
            Spacer(minLength: 0)
            badge
        }
    }

    @ViewBuilder private var badge: some View {
        switch availability {
        case .startOver:
            MetaTag(text: "Depuis le début", systemImage: "backward.end.fill")
        case .available:
            MetaTag(text: "Replay", systemImage: "play.fill")
        default:
            if programme.isAiring(at: now) { MetaTag(text: "En cours") }
        }
    }
}

private struct DimmableText: ViewModifier {
    let dimmed: Bool
    func body(content: Content) -> some View {
        if dimmed { content.tertiaryText() } else { content.primaryText() }
    }
}

// MARK: - Transport (replay)

private struct TransportPanel: View {
    let controller: PlaybackController
    @FocusState private var focus: Int?

    var body: some View {
        VStack {
            Spacer()
            if let archive = controller.archive {
                let length = archive.original.programmeEnd.timeIntervalSince(archive.original.programmeStart)
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 16) {
                        StatusBadge(kind: archive.original.isStartOver ? .startOver : .replay)
                        Text(archive.original.title).font(Theme.Typeface.programme(42)).lineLimit(1)
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }
                    HStack(spacing: 18) {
                        Text(Self.format(controller.archivePosition)).font(Theme.Typeface.time())
                        ProgressLine(progress: length > 0 ? controller.archivePosition / length : 0, tint: Theme.Palette.archive, height: 6)
                        Text(Self.format(length)).font(Theme.Typeface.time())
                    }
                    .foregroundStyle(Theme.Palette.textSecondary)
                    HStack(spacing: 22) {
                        round(0, "backward.end.fill") { controller.restartArchiveFromBeginning() }
                        round(1, "gobackward.5") { controller.seekArchive(by: -300) }
                        round(2, "gobackward.30") { controller.seekArchive(by: -30) }
                        round(3, controller.isPaused ? "play.fill" : "pause.fill") { controller.togglePlayPause() }
                        round(4, "goforward.30") { controller.seekArchive(by: 30) }
                        round(5, "goforward.5") { controller.seekArchive(by: 300) }
                        Spacer()
                        Button { controller.returnToLive() } label: {
                            Label("Revenir au direct", systemImage: "dot.radiowaves.left.and.right")
                                .font(Theme.Typeface.label(24)).primaryText()
                        }
                        .buttonStyle(GlassRowButtonStyle(cornerRadius: 40, horizontalPadding: 30, verticalPadding: 16))
                        .fixedSize()
                        .focused($focus, equals: 9)
                    }
                    if archive.format == .mpegts {
                        Text("Archive à lecture séquentielle : les sauts se font par nouvelle requête (précision : 1 min).")
                            .font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .padding(.horizontal, Theme.Metrics.safeHorizontal)
                .padding(.bottom, Theme.Metrics.safeVertical)
                .padding(.top, 120)
                .background(Theme.Palette.scrimBottom.ignoresSafeArea())
            }
        }
        .ignoresSafeArea()
        .defaultFocus($focus, 3)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focus = 3 } }
        .onExitCommand { controller.panel = .none }
    }

    private func round(_ id: Int, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(RoundIconButtonStyle(diameter: 84))
            .focused($focus, equals: id)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
                             : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Diagnostic « réseau ou fournisseur ? »

/// Trois vérifications (réseau local, Internet, serveur du fournisseur) et une conclusion.
private struct ConnectionSection: View {
    let controller: PlaybackController
    @State private var check: PlaybackController.ConnectionCheck?
    @State private var running = false
    @State private var unavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connexion").sectionHeader().padding(.leading, 22).padding(.top, 14)
            if let check {
                row("Réseau local", check.networkDetail, check.report.network)
                row("Internet", check.internetDetail, check.report.internet)
                row("Fournisseur", check.providerDetail, check.report.provider)
                Text(check.report.conclusion).font(Theme.Typeface.body(22))
                    .foregroundStyle(Theme.Palette.textPrimary).padding(.horizontal, 22).padding(.top, 4)
            } else if unavailable {
                Text("Diagnostic indisponible sans session.").font(Theme.Typeface.body(22))
                    .foregroundStyle(Theme.Palette.textSecondary).padding(.horizontal, 22)
            } else {
                HStack(spacing: 14) {
                    ProgressView().tint(Theme.Palette.textSecondary)
                    Text("Mesure en cours…").font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.horizontal, 22)
            }
            Button { Task { await run() } } label: {
                Label("Tester à nouveau", systemImage: "arrow.clockwise").font(Theme.Typeface.label(22)).primaryText()
            }
            .buttonStyle(GlassRowButtonStyle(horizontalPadding: 22, verticalPadding: 12))
            .disabled(running)
            if let variant = controller.otherVariants.first {
                Button {
                    controller.panel = .none
                    controller.switchVariant(to: variant.id)
                } label: {
                    Label("Essayer la version \(PlaybackController.qualityLabel(variant))", systemImage: "rectangle.stack")
                        .font(Theme.Typeface.label(22)).primaryText()
                }
                .buttonStyle(GlassRowButtonStyle(horizontalPadding: 22, verticalPadding: 12))
            }
        }
        .task { await run() }
    }

    private func run() async {
        guard !running else { return }
        running = true
        check = nil
        check = await controller.checkConnection()
        unavailable = check == nil
        running = false
    }

    private func row(_ title: String, _ detail: String, _ status: ConnectionReport.Status) -> some View {
        HStack(spacing: 14) {
            Circle().fill(color(status)).frame(width: 12, height: 12)
            Text(title).font(Theme.Typeface.label(22)).foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            Text(detail).font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
            // Un mot en plus de la couleur : l'état se lit sans distinguer les teintes.
            Text(word(status)).font(Theme.Typeface.section(18)).foregroundStyle(color(status))
        }
        .padding(.horizontal, 22)
    }

    private func word(_ status: ConnectionReport.Status) -> String {
        switch status {
        case .ok: return "OK"
        case .slow: return "LENT"
        case .failed: return "ÉCHEC"
        }
    }

    private func color(_ status: ConnectionReport.Status) -> Color {
        switch status {
        case .ok: return .green
        case .slow: return .orange
        case .failed: return Theme.Palette.danger
        }
    }
}

// MARK: - Pistes audio et informations

private struct TracksPanel: View {
    let controller: PlaybackController

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Audio").sectionHeader().padding(.leading, 22)
                    let tracks = controller.audioTracks
                    if tracks.isEmpty {
                        Text("Une seule piste disponible.").font(Theme.Typeface.body(24))
                            .foregroundStyle(Theme.Palette.textSecondary).padding(.leading, 22)
                    }
                    ForEach(tracks) { track in
                        Button { controller.selectAudioTrack(track.id); controller.panel = .none } label: {
                            HStack {
                                Text(track.title).font(Theme.Typeface.label(24)).primaryText()
                                Spacer()
                                if track.isSelected { Image(systemName: "checkmark").primaryText() }
                            }
                        }
                        .buttonStyle(GlassRowButtonStyle(horizontalPadding: 22, verticalPadding: 14))
                    }
                    Text("Informations").sectionHeader().padding(.leading, 22).padding(.top, 14)
                    Text(controller.technicalSummary).font(Theme.Typeface.caption(20))
                        .foregroundStyle(Theme.Palette.textSecondary).padding(.horizontal, 22)
                    ConnectionSection(controller: controller)
                }
                .padding(18)
                .frame(width: 720)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial))
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.Palette.night.opacity(0.55)))
            }
        }
        .padding(.horizontal, Theme.Metrics.safeHorizontal)
        .padding(.bottom, Theme.Metrics.safeVertical + 120)
        .onExitCommand { controller.panel = .none }
    }
}
