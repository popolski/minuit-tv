import SwiftUI
import MinuitCore

/// Surcouche du lecteur : bandeau, panneaux, états de chargement et d'erreur.
struct PlayerOverlayView: View {
    let app: AppModel
    @Bindable var controller: PlaybackController

    var body: some View {
        ZStack {
            stateLayer
            if controller.bannerVisible && controller.panel == .none && controller.isLive {
                InfoBanner(app: app, controller: controller)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            switch controller.panel {
            case .channels:
                ChannelPanel(app: app, controller: controller)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .programmes:
                ProgrammePanel(app: app, controller: controller)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .transport:
                TransportPanel(app: app, controller: controller)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .tracks:
                TracksPanel(controller: controller)
                    .transition(.opacity)
            case .none:
                EmptyView()
            }
            if let toast = controller.toast {
                VStack {
                    HStack {
                        Spacer()
                        Text(toast)
                            .font(Theme.Typeface.label())
                            .padding(.horizontal, 28).padding(.vertical, 16)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                }
                .padding(.horizontal, Theme.Metrics.safeHorizontal)
                .padding(.top, Theme.Metrics.safeVertical)
                .transition(.opacity)
            }
        }
        .animation(Theme.Motion.panel, value: controller.panel)
        .animation(Theme.Motion.standard, value: controller.bannerVisible)
        .animation(Theme.Motion.standard, value: controller.toast)
        .foregroundStyle(Theme.Palette.textPrimary)
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
                ProgressView().scaleEffect(1.4).tint(Theme.Palette.moon)
            }
        }
    }
}

// MARK: - États

private struct TuningView: View {
    var title: String?
    var channel: Channel?

    var body: some View {
        VStack(spacing: 24) {
            if let channel { ChannelLogoView(channel: channel, size: CGSize(width: 220, height: 132)) }
            ProgressView().tint(Theme.Palette.moon)
            if let title {
                Text(title).font(Theme.Typeface.label()).foregroundStyle(Theme.Palette.textSecondary)
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
            Theme.Palette.night.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Theme.Palette.ember)
                Text(message).font(Theme.Typeface.title(40)).multilineTextAlignment(.center)
                HStack(spacing: 32) {
                    Button("Réessayer") { controller.retry() }
                    Button("Autres chaînes") { controller.panel = .channels }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 1100)
        }
    }
}

// MARK: - Bandeau d'information

private struct InfoBanner: View {
    let app: AppModel
    let controller: PlaybackController

    var body: some View {
        VStack {
            Spacer()
            ZStack(alignment: .bottom) {
                Theme.Palette.scrimBottom.frame(height: 420).allowsHitTesting(false)
                if let id = controller.displayedChannel, let channel = app.library.channel(id) {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        content(channel: channel, now: context.date)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private func content(channel: Channel, now: Date) -> some View {
        let (current, next) = app.epg.nowNext(channel.id, at: now)
        return HStack(alignment: .top, spacing: 36) {
            ChannelLogoView(channel: channel, size: CGSize(width: 200, height: 120))
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    if let number = channel.number {
                        Text("\(number)").font(Theme.Typeface.time(30)).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Text(channel.name).font(Theme.Typeface.label(30))
                    StatusBadge(kind: .live)
                    if app.isFavorite(channel.id) {
                        Image(systemName: "star.fill").foregroundStyle(Theme.Palette.moon)
                    }
                    if channel.hasAnnouncedArchive {
                        Label("Replay \(channel.archive?.days ?? 0) j", systemImage: "clock.arrow.circlepath")
                            .font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.archive)
                    }
                    if controller.isPaused {
                        Label("En pause", systemImage: "pause.fill").font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.ember)
                    }
                }
                if let current {
                    Text(current.title).font(Theme.Typeface.display(46)).lineLimit(1)
                    HStack(spacing: 16) {
                        Text(current.start.clockText).font(Theme.Typeface.time())
                        ProgressLine(progress: current.progress(at: now)).frame(width: 520)
                        Text(current.end.clockText).font(Theme.Typeface.time())
                        Text("· reste \(max(0, Int(current.end.timeIntervalSince(now) / 60))) min")
                            .font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    Text("Programme non communiqué").font(Theme.Typeface.title(36)).foregroundStyle(Theme.Palette.textSecondary)
                }
                if let next {
                    HStack(spacing: 12) {
                        Text("Ensuite").font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.textTertiary)
                        Text(next.start.clockText).font(Theme.Typeface.time(22)).foregroundStyle(Theme.Palette.textSecondary)
                        Text(next.title).font(Theme.Typeface.body(26)).lineLimit(1)
                    }
                }
                Text("◀ Chaînes   ▶ Programmes   ▲▼ Zapper   Appui long : favori")
                    .font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.top, 6)
            }
            Spacer()
            Text(now.clockText).font(Theme.Typeface.time(34)).foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.horizontal, Theme.Metrics.safeHorizontal)
        .padding(.bottom, Theme.Metrics.safeVertical + 10)
        .onAppear { app.epg.ensureFresh([channel.id]) }
    }
}

// MARK: - Panneau des chaînes (mini-guide)

private struct ChannelPanel: View {
    let app: AppModel
    let controller: PlaybackController
    @FocusState private var focused: ChannelID?

    var body: some View {
        let channels = app.channels(in: controller.zapContext)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(Theme.Typeface.title(34)).padding(.leading, 24)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(channels) { channel in
                                Button { controller.playLive(channel.id); controller.panel = .none } label: {
                                    ChannelPanelRow(app: app, channel: channel, isCurrent: channel.id == controller.displayedChannel)
                                }
                                .buttonStyle(MinuitRowButtonStyle())
                                .focused($focused, equals: channel.id)
                                .id(channel.id)
                                .onAppear { app.epg.ensureFresh([channel.id]) }
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onAppear {
                        if let current = controller.displayedChannel {
                            proxy.scrollTo(current, anchor: .center)
                            focused = current
                        }
                    }
                }
            }
            .padding(.vertical, Theme.Metrics.safeVertical)
            .padding(.leading, Theme.Metrics.safeHorizontal - 24)
            .frame(width: 820)
            .background(Theme.Palette.scrimLeading.ignoresSafeArea())
            Spacer()
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

private struct ChannelPanelRow: View {
    let app: AppModel
    let channel: Channel
    let isCurrent: Bool

    var body: some View {
        let (current, _) = app.epg.nowNext(channel.id)
        HStack(spacing: 20) {
            ChannelLogoView(channel: channel, size: CGSize(width: 96, height: 58))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(channel.name).font(Theme.Typeface.label(26)).lineLimit(1)
                    if isCurrent { Circle().fill(Theme.Palette.ember).frame(width: 10, height: 10) }
                }
                if let current {
                    Text(current.title).font(Theme.Typeface.body(22)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                    ProgressLine(progress: current.progress(at: Date()), height: 3).frame(width: 360)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Panneau des programmes (avant / après, replay)

private struct ProgrammePanel: View {
    let app: AppModel
    let controller: PlaybackController
    @FocusState private var focused: String?

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                if let id = controller.displayedChannel, let channel = app.library.channel(id) {
                    HStack {
                        Text(channel.name).font(Theme.Typeface.title(34))
                        Spacer()
                        Button { controller.panel = .tracks } label: {
                            Label("Audio et infos", systemImage: "waveform").font(Theme.Typeface.caption())
                        }
                        .buttonStyle(MinuitRowButtonStyle())
                        .frame(width: 280)
                    }
                    .padding(.leading, 24)
                    list(for: channel)
                        .task { await app.epg.loadDetailed(channel.id) }
                }
            }
            .padding(.vertical, Theme.Metrics.safeVertical)
            .padding(.trailing, Theme.Metrics.safeHorizontal - 24)
            .frame(width: 900)
            .background(LinearGradient(colors: [Theme.Palette.night.opacity(0), Theme.Palette.night.opacity(0.96)],
                                       startPoint: .leading, endPoint: .trailing).ignoresSafeArea())
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
                LazyVStack(alignment: .leading, spacing: 4) {
                    if programmes.isEmpty {
                        Text("Aucun programme communiqué pour cette chaîne.")
                            .font(Theme.Typeface.body()).foregroundStyle(Theme.Palette.textSecondary).padding(24)
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
                        .buttonStyle(MinuitRowButtonStyle())
                        .focused($focused, equals: programme.id)
                        .id(programme.id)
                    }
                }
            }
            .onAppear {
                if let currentID {
                    proxy.scrollTo(currentID, anchor: .center)
                    focused = currentID
                }
            }
        }
    }
}

struct ProgrammeRow: View {
    let programme: Programme
    let availability: CatchupAvailability
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(programme.start.clockText).font(Theme.Typeface.time(24)).foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(programme.title).font(Theme.Typeface.title(28)).lineLimit(1)
                    .foregroundStyle(programme.hasEnded(at: now) && availability.window == nil ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
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
            Label("Début", systemImage: "backward.end.fill").font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.archive)
        case .available:
            Label("Replay", systemImage: "play.circle").font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.archive)
        default:
            EmptyView()
        }
    }
}

// MARK: - Transport (replay)

private struct TransportPanel: View {
    let app: AppModel
    let controller: PlaybackController
    @FocusState private var focus: Int?

    var body: some View {
        VStack {
            Spacer()
            if let archive = controller.archive {
                let length = archive.original.programmeEnd.timeIntervalSince(archive.original.programmeStart)
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        StatusBadge(kind: archive.original.isStartOver ? .startOver : .replay)
                        Text(archive.original.title).font(Theme.Typeface.display(42)).lineLimit(1)
                    }
                    HStack(spacing: 16) {
                        Text(Self.format(controller.archivePosition)).font(Theme.Typeface.time())
                        ProgressLine(progress: length > 0 ? controller.archivePosition / length : 0, tint: Theme.Palette.archive, height: 6)
                        Text(Self.format(length)).font(Theme.Typeface.time())
                    }
                    .foregroundStyle(Theme.Palette.textSecondary)
                    HStack(spacing: 24) {
                        transportButton(0, "backward.end.fill", "Début") { controller.restartArchiveFromBeginning() }
                        transportButton(1, "gobackward.5", "−5 min") { controller.seekArchive(by: -300) }
                        transportButton(2, "gobackward.30", "−30 s") { controller.seekArchive(by: -30) }
                        transportButton(3, controller.isPaused ? "play.fill" : "pause.fill", controller.isPaused ? "Lecture" : "Pause") {
                            controller.togglePlayPause()
                        }
                        transportButton(4, "goforward.30", "+30 s") { controller.seekArchive(by: 30) }
                        transportButton(5, "goforward.5", "+5 min") { controller.seekArchive(by: 300) }
                        Spacer()
                        Button { controller.returnToLive() } label: {
                            Label("Revenir au direct", systemImage: "dot.radiowaves.left.and.right")
                                .font(Theme.Typeface.label())
                                .padding(.horizontal, 20).padding(.vertical, 12)
                        }
                        .buttonStyle(MinuitCardButtonStyle(cornerRadius: 30))
                        .focused($focus, equals: 9)
                    }
                    if archive.format == .mpegts {
                        Text("Archive à lecture séquentielle : les sauts se font par nouvelle requête (précision : 1 min).")
                            .font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .padding(.horizontal, Theme.Metrics.safeHorizontal)
                .padding(.vertical, 40)
                .background(Theme.Palette.scrimBottom.ignoresSafeArea())
            }
        }
        .onAppear { focus = 3 }
        .onExitCommand { controller.panel = .none }
    }

    private func transportButton(_ id: Int, _ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 30, weight: .medium))
                Text(label).font(Theme.Typeface.caption(18))
            }
            .frame(width: 120, height: 96)
        }
        .buttonStyle(MinuitCardButtonStyle())
        .focused($focus, equals: id)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
                             : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Pistes audio

private struct TracksPanel: View {
    let controller: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pistes audio").font(Theme.Typeface.title(34))
            let tracks = controller.audioTracks
            if tracks.isEmpty {
                Text("Une seule piste disponible.").foregroundStyle(Theme.Palette.textSecondary)
            }
            ForEach(tracks) { track in
                Button { controller.selectAudioTrack(track.id); controller.panel = .none } label: {
                    HStack {
                        Text(track.title)
                        Spacer()
                        if track.isSelected { Image(systemName: "checkmark") }
                    }
                }
                .buttonStyle(MinuitRowButtonStyle())
            }
            Text(controller.technicalSummary).font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(48)
        .frame(width: 900)
        .background(RoundedRectangle(cornerRadius: Theme.Metrics.corner).fill(Theme.Palette.night.opacity(0.94)))
        .onExitCommand { controller.panel = .none }
    }
}
