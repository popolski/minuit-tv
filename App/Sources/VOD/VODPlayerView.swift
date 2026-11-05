import SwiftUI
import UIKit
import MinuitCore

/// Lecteur plein écran des films et épisodes.
///
/// Siri Remote :
///  Clic central ou Lecture/Pause : pause / reprise
///  ◀ / ▶ : −10 s / +10 s     maintenus : retour / avance rapides, de plus en plus vite
///  ▲ : informations     ▼ : audio et sous-titres
///  Retour : ferme le panneau, masque les informations, puis quitte (position enregistrée).
final class VODPlayerViewController: UIViewController {
    private let controller: VODPlayerController
    private let onDismiss: () -> Void
    private var overlay: UIHostingController<VODPlayerOverlay>!
    private var observing = true
    private var holdTask: Task<Void, Never>?

    init(controller: VODPlayerController, onDismiss: @escaping () -> Void) {
        self.controller = controller
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non pris en charge") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let host = controller.hostView
        host.frame = view.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host)

        overlay = UIHostingController(rootView: VODPlayerOverlay(controller: controller, close: { [weak self] in self?.dismissPlayer() }))
        overlay.view.backgroundColor = .clear
        addChild(overlay)
        overlay.view.frame = view.bounds
        overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay.view)
        overlay.didMove(toParent: self)

        controller.onFinished = { [weak self] in self?.dismissPlayer() }
        observeOverlay()
        controller.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        DiagnosticsLog.shared.log(.info, "vod", "Lecteur affiché")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        observing = false
    }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Focus

    private func observeOverlay() {
        guard observing else { return }
        withObservationTracking {
            _ = controller.needsInteractiveOverlay
        } onChange: { [weak self] in
            let target = self
            DispatchQueue.main.async {
                target?.overlayDidChange()
                target?.observeOverlay()
            }
        }
        overlayDidChange()
    }

    private func overlayDidChange() {
        overlay.view.isUserInteractionEnabled = controller.needsInteractiveOverlay
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        if !controller.needsInteractiveOverlay { becomeFirstResponder() }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        controller.needsInteractiveOverlay ? [overlay] : []
    }

    // MARK: Télécommande

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !controller.needsInteractiveOverlay, let press = presses.first else {
            super.pressesBegan(presses, with: event)
            return
        }
        switch press.type {
        case .leftArrow, .rightArrow:
            let forward = press.type == .rightArrow
            holdTask?.cancel()
            holdTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard let self, !Task.isCancelled else { return }
                self.controller.startShuttle(forward: forward)
            }
        case .upArrow, .downArrow, .menu, .playPause, .select:
            break
        default:
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first else {
            super.pressesEnded(presses, with: event)
            return
        }
        if controller.needsInteractiveOverlay {
            if press.type == .menu {
                if controller.panel != .none {
                    controller.panel = .none
                } else if controller.nextCountdown != nil {
                    controller.cancelNext()
                } else {
                    dismissPlayer()
                }
                return
            }
            super.pressesEnded(presses, with: event)
            return
        }
        switch press.type {
        case .leftArrow, .rightArrow:
            holdTask?.cancel()
            holdTask = nil
            if controller.isShuttling {
                controller.stopShuttle()
            } else {
                controller.skip(by: press.type == .rightArrow ? 10 : -10)
            }
        case .select, .playPause:
            if controller.isShuttling { controller.stopShuttle() } else { controller.togglePlayPause() }
        case .upArrow:
            controller.showChrome()
        case .downArrow:
            controller.panel = .tracks
            controller.showChrome()
        case .menu:
            if controller.chromeVisible && !controller.isPaused && controller.phase == .playing {
                controller.chromeVisible = false
            } else {
                dismissPlayer()
            }
        default:
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        holdTask?.cancel()
        holdTask = nil
        if controller.isShuttling { controller.stopShuttle() }
        super.pressesCancelled(presses, with: event)
    }

    private func dismissPlayer() {
        guard observing else { return }
        observing = false
        controller.close()
        onDismiss()
    }
}

/// Pont SwiftUI → lecteur UIKit.
struct VODPlayerScreen: UIViewControllerRepresentable {
    let app: AppModel
    let item: VODPlayItem
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> VODPlayerViewController {
        VODPlayerViewController(controller: VODPlayerController(item: item, app: app), onDismiss: onDismiss)
    }

    func updateUIViewController(_ controller: VODPlayerViewController, context: Context) {}
}

// MARK: - Surcouche

struct VODPlayerOverlay: View {
    let controller: VODPlayerController
    let close: () -> Void

    var body: some View {
        ZStack {
            // Repère des tests d'interface : présent tant que le lecteur est affiché.
            Color.clear
                .accessibilityElement()
                .accessibilityLabel("Lecteur")
                .accessibilityIdentifier("vod-player")
            SubtitleLayer(cues: controller.cues, raised: controller.chromeVisible)
            if controller.phase == .loading || (controller.isBuffering && controller.scrubTarget == nil) {
                ProgressView().tint(.white).scaleEffect(1.6)
            }
            if controller.chromeVisible || controller.isPaused || controller.scrubTarget != nil {
                VODChrome(controller: controller)
                    .transition(.opacity)
            }
            if let toast = controller.toast {
                VStack {
                    Text(toast).font(Theme.Typeface.label(26)).foregroundStyle(.white)
                        .padding(.horizontal, 26).padding(.vertical, 12)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                    Spacer()
                }
                .padding(.top, 60)
            }
            if controller.panel == .tracks {
                HStack {
                    Spacer()
                    VODTracksPanel(controller: controller)
                }
                .transition(.move(edge: .trailing))
            }
            if let countdown = controller.nextCountdown, let next = controller.nextItem {
                VODNextCard(controller: controller, next: next, countdown: countdown)
            }
            if case .failed(let message) = controller.phase {
                VODFailureCard(message: message, retry: { controller.retry() }, close: close)
            }
        }
        .animation(Theme.Motion.standard, value: controller.chromeVisible)
        .animation(Theme.Motion.panel, value: controller.panel)
        .ignoresSafeArea()
    }
}

private struct VODChrome: View {
    let controller: VODPlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .lastTextBaseline, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(controller.item.title).font(Theme.Typeface.display(46)).foregroundStyle(.white).lineLimit(1)
                        if let subtitle = controller.item.subtitle {
                            Text(subtitle).font(Theme.Typeface.label(26)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if let rate = controller.shuttleRate {
                        Label("×\(Int(abs(rate) / 10))", systemImage: rate > 0 ? "forward.fill" : "backward.fill")
                            .font(Theme.Typeface.label(28)).foregroundStyle(.white)
                    } else if controller.isPaused {
                        Image(systemName: "pause.fill").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 10) {
                        VODProgressBar(position: controller.displayedPosition, duration: controller.duration,
                                       scrubbing: controller.scrubTarget != nil)
                        HStack {
                            Text(VODFormat.clock(controller.displayedPosition))
                            Spacer()
                            if let end = controller.endTime {
                                Text("Fin à \(end.clockText)").foregroundStyle(Theme.Palette.textSecondary)
                                Spacer()
                            }
                            Text(controller.duration > 0 ? "−" + VODFormat.clock(controller.duration - controller.displayedPosition) : "")
                        }
                        .font(Theme.Typeface.time(24)).foregroundStyle(.white)
                    }
                }
                Text("◀ ▶ : 10 s · maintenir : avance rapide · ▼ : audio et sous-titres")
                    .font(Theme.Typeface.caption(19)).foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 60)
            .padding(.top, 140)
            .background(LinearGradient(colors: [.clear, Color.black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        }
        .allowsHitTesting(false)
    }
}

private struct VODProgressBar: View {
    let position: Double
    let duration: Double
    let scrubbing: Bool

    var body: some View {
        GeometryReader { proxy in
            let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(Theme.Palette.ember).frame(width: max(8, proxy.size.width * fraction))
                Circle().fill(.white)
                    .frame(width: scrubbing ? 26 : 18, height: scrubbing ? 26 : 18)
                    .offset(x: proxy.size.width * fraction - (scrubbing ? 13 : 9))
            }
        }
        .frame(height: 8)
    }
}

/// Sous-titres dessinés par Minuit (moteur AetherEngine) : texte ou images PGS/DVB.
private struct SubtitleLayer: View {
    let cues: [DisplayCue]
    /// Remontés quand les informations sont affichées, pour ne pas les masquer.
    let raised: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(cues) { cue in
                    switch cue.body {
                    case .text(let text, let italic):
                        Text(text)
                            .font(.system(size: 46, weight: .semibold))
                            .italic(italic)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 2)
                            .shadow(color: .black.opacity(0.8), radius: 6, y: 2)
                            .frame(maxWidth: geo.size.width * 0.85)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cue.top ? .top : .bottom)
                            .padding(.bottom, cue.top ? 0 : geo.size.height * (raised ? 0.3 : 0.08))
                            .padding(.top, cue.top ? geo.size.height * 0.06 : 0)
                    case .image(let image, let rect, let canvas):
                        let cw = canvas.width > 0 ? canvas.width : 1920
                        let ch = canvas.height > 0 ? canvas.height : 1080
                        let scale = min(geo.size.width / cw, geo.size.height / ch)
                        let ox = (geo.size.width - cw * scale) / 2
                        let oy = (geo.size.height - ch * scale) / 2
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: rect.width * scale, height: rect.height * scale)
                            .position(x: ox + rect.midX * scale, y: oy + rect.midY * scale)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}

private struct VODTracksPanel: View {
    let controller: VODPlayerController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Audio").sectionHeader().padding(.leading, 8)
                if controller.audioTracks.isEmpty {
                    Text("Piste unique").font(Theme.Typeface.body(22)).foregroundStyle(Theme.Palette.textTertiary).padding(.leading, 8)
                }
                ForEach(controller.audioTracks) { track in
                    row(track.title, selected: track.isSelected) { controller.selectAudio(track.id) }
                }
                Text("Sous-titres").sectionHeader().padding(.leading, 8).padding(.top, 20)
                row("Désactivés", selected: !controller.subtitleTracks.contains(where: \.isSelected)) { controller.selectSubtitle(nil) }
                ForEach(controller.subtitleTracks) { track in
                    row(track.title, selected: track.isSelected) { controller.selectSubtitle(track.id) }
                }
            }
            .padding(30)
        }
        .frame(width: 560)
        .frame(maxHeight: .infinity)
        .background(Theme.Palette.night.opacity(0.92))
    }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).opacity(selected ? 1 : 0).primaryText()
                Text(title).font(Theme.Typeface.label(23)).lineLimit(1).primaryText()
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(GlassRowButtonStyle(isSelected: selected, horizontalPadding: 18, verticalPadding: 12))
    }
}

private struct VODNextCard: View {
    let controller: VODPlayerController
    let next: VODPlayItem
    let countdown: Int

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Épisode suivant dans \(countdown) s").sectionHeader()
                    Text(next.subtitle ?? next.title).font(Theme.Typeface.title(32)).foregroundStyle(.white).lineLimit(2)
                    HStack(spacing: 18) {
                        Button { controller.playNext() } label: {
                            Label("Lire maintenant", systemImage: "play.fill").font(Theme.Typeface.label(24)).primaryText()
                        }
                        .buttonStyle(GlassRowButtonStyle(cornerRadius: 34, horizontalPadding: 28, verticalPadding: 12))
                        .fixedSize()
                        Button { controller.cancelNext() } label: {
                            Text("Fermer").font(Theme.Typeface.label(24)).primaryText()
                        }
                        .buttonStyle(GlassRowButtonStyle(cornerRadius: 34, horizontalPadding: 28, verticalPadding: 12))
                        .fixedSize()
                    }
                }
                .padding(34)
                .frame(width: 640, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.Palette.night.opacity(0.92)))
            }
        }
        .padding(70)
    }
}

private struct VODFailureCard: View {
    let message: String
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 60)).foregroundStyle(Theme.Palette.ember)
            Text(message).font(Theme.Typeface.title(34)).foregroundStyle(.white).multilineTextAlignment(.center)
                .frame(maxWidth: 1100)
            HStack(spacing: 24) {
                Button(action: retry) { Label("Réessayer", systemImage: "arrow.clockwise").font(Theme.Typeface.label(25)).primaryText() }
                    .buttonStyle(GlassRowButtonStyle(cornerRadius: 36, horizontalPadding: 32, verticalPadding: 14))
                    .fixedSize()
                Button(action: close) { Text("Fermer").font(Theme.Typeface.label(25)).primaryText() }
                    .buttonStyle(GlassRowButtonStyle(cornerRadius: 36, horizontalPadding: 32, verticalPadding: 14))
                    .fixedSize()
            }
        }
        .padding(60)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.Palette.night.opacity(0.92)))
    }
}
