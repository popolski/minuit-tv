import SwiftUI
import UIKit
import MinuitCore

/// Grille du guide. Fenêtre glissante de 12 h (re-calculée en atteignant un bord)
/// pour garder un nombre de cases borné même avec des milliers de chaînes.
final class GuideViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, GuideLayoutDataSource {
    private let app: AppModel
    private let onSelect: (Programme?, Channel) -> Void
    /// Retour : remonte vers la barre du haut au lieu de quitter l'application.
    var onBack: (() -> Void)?
    /// Case focalisée (programme, ou trou du guide), pour la fiche en tête d'écran.
    var onFocus: ((Programme?, Channel) -> Void)?
    private let layout = GuideLayout()
    private var collectionView: UICollectionView!

    private(set) var timeline: GuideTimeline
    private var channels: [Channel] = []
    private var slotCache: [Int: [EPGSlot]] = [:]
    private var lastRevision = -1
    private var fetchWorkItem: DispatchWorkItem?
    private var observing = true

    static let windowHours: Double = 12
    static let pointsPerMinute: Double = 9

    init(app: AppModel, onSelect: @escaping (Programme?, Channel) -> Void) {
        self.app = app
        self.onSelect = onSelect
        timeline = GuideTimeline.around(Date(), pastHours: 1.5, futureHours: Self.windowHours - 1.5,
                                        pointsPerMinute: Self.pointsPerMinute, timeZone: .current)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        layout.dataSource = self
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.register(ProgrammeCell.self, forCellWithReuseIdentifier: ProgrammeCell.reuseIdentifier)
        collectionView.register(ChannelHeaderView.self, forSupplementaryViewOfKind: GuideLayout.channelHeaderKind,
                                withReuseIdentifier: ChannelHeaderView.reuseIdentifier)
        collectionView.register(TimeHeaderView.self, forSupplementaryViewOfKind: GuideLayout.timeHeaderKind,
                                withReuseIdentifier: TimeHeaderView.reuseIdentifier)
        collectionView.register(NowLineView.self, forSupplementaryViewOfKind: GuideLayout.nowLineKind,
                                withReuseIdentifier: NowLineView.reuseIdentifier)
        view.addSubview(collectionView)
        reloadChannels()
        observeEPG()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        observing = true
        if channels.count != app.channels(in: .all).count { reloadChannels() }
        scrollToNow(animated: false)
        requestVisibleEPG()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        observing = false
    }

    // MARK: Données

    func reloadChannels() {
        channels = app.channels(in: .all)
        slotCache.removeAll()
        layout.invalidateRows()
        collectionView?.reloadData()
    }

    private func observeEPG() {
        withObservationTracking {
            _ = app.epg.revision
        } onChange: { [weak self] in
            let target = self
            DispatchQueue.main.async {
                target?.epgDidChange()
                target?.observeEPG()
            }
        }
    }

    /// Nouvelles données de guide : on recalcule uniquement les lignes en cache
    /// et on recharge celles qui ont changé, sans perdre le focus.
    private func epgDidChange() {
        guard isViewLoaded else { return }
        var changed = IndexSet()
        for (row, old) in slotCache {
            let fresh = computeSlots(row)
            if fresh != old {
                slotCache[row] = fresh
                changed.insert(row)
            }
        }
        guard !changed.isEmpty else { return }
        layout.invalidateRows()
        UIView.performWithoutAnimation {
            collectionView.reloadSections(changed)
        }
    }

    private func computeSlots(_ row: Int) -> [EPGSlot] {
        guard channels.indices.contains(row) else { return [] }
        return app.epg.index.slots(for: channels[row].id, in: timeline.interval, minimumGap: 5 * 60)
    }

    private func slots(_ row: Int) -> [EPGSlot] {
        if let cached = slotCache[row] { return cached }
        let value = computeSlots(row)
        slotCache[row] = value
        return value
    }

    var rowCount: Int { channels.count }

    func spans(forRow row: Int) -> [(x: Double, width: Double)] {
        slots(row).map { timeline.span(for: $0.interval) ?? (0, 0) }
    }

    // MARK: Fenêtre temporelle

    func scrollToNow(animated: Bool) {
        let x = max(0, layout.x(for: Date().addingTimeInterval(-30 * 60)) - layout.channelColumnWidth)
        collectionView.setContentOffset(CGPoint(x: x, y: collectionView.contentOffset.y), animated: animated)
    }

    func shiftWindow(byHours hours: Double, anchor: Date? = nil) {
        let origin = timeline.origin.addingTimeInterval(hours * 3600)
        timeline = GuideTimeline(origin: origin, end: origin.addingTimeInterval(Self.windowHours * 3600),
                                 pointsPerMinute: Self.pointsPerMinute, timeZone: .current)
        slotCache.removeAll()
        layout.invalidateRows()
        collectionView.reloadData()
        if let anchor {
            let x = max(0, layout.x(for: anchor) - layout.channelColumnWidth - 200)
            collectionView.setContentOffset(CGPoint(x: x, y: collectionView.contentOffset.y), animated: false)
        }
        requestVisibleEPG()
    }

    func jumpToNow() {
        timeline = GuideTimeline.around(Date(), pastHours: 1.5, futureHours: Self.windowHours - 1.5,
                                        pointsPerMinute: Self.pointsPerMinute, timeZone: .current)
        slotCache.removeAll()
        layout.invalidateRows()
        collectionView.reloadData()
        scrollToNow(animated: false)
    }

    // MARK: UICollectionViewDataSource

    func numberOfSections(in collectionView: UICollectionView) -> Int { channels.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        slots(section).count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ProgrammeCell.reuseIdentifier, for: indexPath) as! ProgrammeCell
        let rowSlots = slots(indexPath.section)
        guard rowSlots.indices.contains(indexPath.item) else { return cell }
        let now = Date()
        let channel = channels[indexPath.section]
        switch rowSlots[indexPath.item] {
        case .programme(let programme):
            let availability = CatchupEvaluator.evaluate(programme: programme, channel: channel, now: now, settings: app.settings.catchup)
            cell.configure(.init(title: programme.title,
                                 timeText: "\(programme.start.clockText) – \(programme.end.clockText)",
                                 isNow: programme.isAiring(at: now), isPast: programme.hasEnded(at: now),
                                 hasReplay: availability.window != nil && !programme.isAiring(at: now),
                                 isGap: false, progress: programme.progress(at: now)))
        case .gap(let interval):
            cell.configure(.init(title: "Programme non communiqué", timeText: interval.start.clockText,
                                 isNow: interval.contains(now), isPast: interval.end <= now,
                                 hasReplay: false, isGap: true, progress: 0))
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        switch kind {
        case GuideLayout.channelHeaderKind:
            let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: ChannelHeaderView.reuseIdentifier,
                                                                       for: indexPath) as! ChannelHeaderView
            if channels.indices.contains(indexPath.section) {
                let channel = channels[indexPath.section]
                view.configure(channel: channel, isFavorite: app.isFavorite(channel.id))
            }
            return view
        case GuideLayout.timeHeaderKind:
            let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: TimeHeaderView.reuseIdentifier,
                                                                       for: indexPath) as! TimeHeaderView
            view.configure(timeline: timeline, channelColumnWidth: layout.channelColumnWidth)
            return view
        default:
            return collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: NowLineView.reuseIdentifier, for: indexPath)
        }
    }

    // MARK: UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard channels.indices.contains(indexPath.section) else { return }
        let channel = channels[indexPath.section]
        let rowSlots = slots(indexPath.section)
        guard rowSlots.indices.contains(indexPath.item) else { return }
        if case .programme(let programme) = rowSlots[indexPath.item] {
            onSelect(programme, channel)
        } else {
            onSelect(nil, channel)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard let indexPath = context.nextFocusedIndexPath else { return }
        let rowSlots = slots(indexPath.section)
        guard rowSlots.indices.contains(indexPath.item) else { return }
        let interval = rowSlots[indexPath.item].interval
        if channels.indices.contains(indexPath.section) {
            if case .programme(let programme) = rowSlots[indexPath.item] {
                onFocus?(programme, channels[indexPath.section])
            } else {
                onFocus?(nil, channels[indexPath.section])
            }
        }
        // Bord de fenêtre atteint : on fait glisser la fenêtre en gardant le programme focalisé à l'écran.
        if indexPath.item == rowSlots.count - 1, interval.end >= timeline.end.addingTimeInterval(-60) {
            DispatchQueue.main.async { self.shiftWindow(byHours: 6, anchor: interval.start) }
        } else if indexPath.item == 0, interval.start <= timeline.origin.addingTimeInterval(60),
                  timeline.origin > Date().addingTimeInterval(-Double(maxArchiveDays()) * 86_400) {
            DispatchQueue.main.async { self.shiftWindow(byHours: -6, anchor: interval.start) }
        }
    }

    private func maxArchiveDays() -> Int { max(1, channels.compactMap { $0.archive?.days }.max() ?? 1) }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), onBack != nil { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), let onBack {
            onBack()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        fetchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestVisibleEPG() }
        fetchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Ne demande le guide que pour les chaînes visibles (plus une marge).
    private func requestVisibleEPG() {
        guard isViewLoaded, !channels.isEmpty else { return }
        let stride = layout.rowHeight + layout.rowSpacing
        let first = max(0, Int((collectionView.contentOffset.y - layout.timeHeaderHeight) / stride) - 3)
        let last = min(channels.count - 1, first + Int(collectionView.bounds.height / stride) + 6)
        guard first <= last else { return }
        app.epg.ensureFresh(channels[first...last].map(\.id))
    }
}

/// Écran « Guide TV » : en-tête (jour, heure, navigation) + grille UIKit.
struct GuideScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(\.backToTopBar) private var backToTopBar
    @State private var selected: (programme: Programme, channel: Channel)?
    @State private var showDetail = false
    @State private var proxy = GuideProxy()
    @State private var focus: (programme: Programme?, channel: Channel)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(DayLabel.label(for: context.date, relativeTo: context.date, timeZone: .current))
                        .font(Theme.Typeface.title(36)).foregroundStyle(Theme.Palette.textPrimary)
                    Text(context.date.clockText).font(Theme.Typeface.time(30)).foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                guideButton("Plus tôt", "chevron.left") { proxy.controller?.shiftWindow(byHours: -6) }
                guideButton("Maintenant", "dot.radiowaves.left.and.right") { proxy.controller?.jumpToNow() }
                guideButton("Plus tard", "chevron.right") { proxy.controller?.shiftWindow(byHours: 6) }
            }
            .font(Theme.Typeface.label(24))
            .padding(.horizontal, Theme.Metrics.safeHorizontal)
            .focusSection()

            GuideFocusHeader(app: app, programme: focus?.programme, channel: focus?.channel)
                .padding(.horizontal, Theme.Metrics.safeHorizontal)

            GuideGrid(app: app, proxy: proxy, onBack: backToTopBar, onFocus: { focus = ($0, $1) }) { programme, channel in
                guard let programme else {
                    router.watch(channel.id, context: .all, app: app)
                    return
                }
                if programme.isAiring(at: Date()) {
                    router.watch(channel.id, context: .all, app: app)
                } else {
                    selected = (programme, channel)
                    showDetail = true
                }
            }
            .focusSection()
        }
        .padding(.top, 10)
        .onExitCommand { backToTopBar() }
        .sheet(isPresented: $showDetail) {
            if let selected {
                ProgrammeDetailView(programme: selected.programme, channel: selected.channel)
            }
        }
    }
}

private func guideButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Label(title, systemImage: symbol).font(Theme.Typeface.label(22)).primaryText()
    }
    .buttonStyle(GlassRowButtonStyle(cornerRadius: 30, horizontalPadding: 22, verticalPadding: 10))
    .fixedSize()
}

/// Fiche de la case focalisée, au-dessus de la grille : logo, état, horaires, titre, résumé.
/// Hauteur fixe : la grille ne saute pas quand le résumé change de longueur.
private struct GuideFocusHeader: View {
    let app: AppModel
    let programme: Programme?
    let channel: Channel?

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            if let channel {
                ChannelLogoView(channel: channel, size: CGSize(width: 220, height: 124))
                VStack(alignment: .leading, spacing: 8) {
                    if let programme {
                        let now = Date()
                        HStack(spacing: 14) {
                            if programme.isAiring(at: now) {
                                StatusBadge(kind: .live)
                            } else if programme.hasEnded(at: now) {
                                let availability = CatchupEvaluator.evaluate(programme: programme, channel: channel,
                                                                             now: now.addingTimeInterval(app.session?.server.clockSkew ?? 0),
                                                                             settings: app.settings.catchup)
                                if availability.window != nil { StatusBadge(kind: .replay) }
                            }
                            Text("\(channel.name) · \(programme.start.clockText) – \(programme.end.clockText)")
                                .font(Theme.Typeface.time(22)).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Text(programme.title).font(Theme.Typeface.programme(42)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                        Text(programme.summary ?? " ").font(Theme.Typeface.body(22)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
                    } else {
                        Text(channel.name).font(Theme.Typeface.label(30)).foregroundStyle(Theme.Palette.textPrimary)
                        Text("Programme non communiqué").font(Theme.Typeface.programme(36)).foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            } else {
                Text("Choisissez un programme pour afficher sa fiche.")
                    .font(Theme.Typeface.body(24)).foregroundStyle(Theme.Palette.textTertiary)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 150, alignment: .top)
        .animation(Theme.Motion.standard, value: programme?.id)
    }
}

@MainActor
final class GuideProxy {
    weak var controller: GuideViewController?
}

private struct GuideGrid: UIViewControllerRepresentable {
    let app: AppModel
    let proxy: GuideProxy
    let onBack: () -> Void
    let onFocus: (Programme?, Channel) -> Void
    let onSelect: (Programme?, Channel) -> Void

    func makeUIViewController(context: Context) -> GuideViewController {
        let controller = GuideViewController(app: app, onSelect: onSelect)
        controller.onBack = onBack
        controller.onFocus = onFocus
        proxy.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: GuideViewController, context: Context) {}
}
