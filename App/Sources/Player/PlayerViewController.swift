import SwiftUI
import UIKit
import MinuitCore

/// Lecteur plein écran. UIKit gère la télécommande (appuis, balayages, appui long)
/// pour un contrôle exact ; la surcouche (bandeau, panneaux) est en SwiftUI.
///
/// Correspondance Siri Remote, direct sans panneau :
///  ▲ / ▼ (clic ou balayage) : chaîne précédente / suivante
///  ◀ : panneau des chaînes     ▶ : panneau des programmes (replay)
///  Clic central : commandes (pistes, favori, format…)     Appui long central : favori
///  Lecture/Pause : pause du direct (tampon local)     Retour : ferme le panneau, puis le lecteur
/// En replay : ◀ / ▶ = −30 s / +30 s, ▲ / ▼ = barre de transport (Début, Direct…).
final class PlayerViewController: UIViewController {
    private let app: AppModel
    private let onDismiss: () -> Void
    private var overlay: UIHostingController<PlayerOverlayView>!
    private var observing = true

    init(app: AppModel, onDismiss: @escaping () -> Void) {
        self.app = app
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non pris en charge") }

    private var controller: PlaybackController { app.playback }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let host = controller.hostView
        host.frame = view.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host)

        overlay = UIHostingController(rootView: PlayerOverlayView(app: app, controller: controller))
        overlay.view.backgroundColor = .clear
        addChild(overlay)
        overlay.view.frame = view.bounds
        overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay.view)
        overlay.didMove(toParent: self)

        installGestures()
        observePanel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        observing = false
    }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Focus

    /// La surcouche ne reçoit le focus que lorsqu'un panneau est ouvert ;
    /// sinon les appuis arrivent ici (zapping).
    private func observePanel() {
        guard observing else { return }
        withObservationTracking {
            _ = controller.panel
            _ = controller.phase
        } onChange: { [weak self] in
            let target = self
            DispatchQueue.main.async {
                target?.panelDidChange()
                target?.observePanel()
            }
        }
        panelDidChange()
    }

    private var overlayNeedsFocus: Bool {
        if controller.panel != .none { return true }
        if case .failed = controller.phase { return true }
        return false
    }

    private func panelDidChange() {
        overlay.view.isUserInteractionEnabled = overlayNeedsFocus
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        if !overlayNeedsFocus { becomeFirstResponder() }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        overlayNeedsFocus ? [overlay] : []
    }

    // MARK: Gestes

    private func installGestures() {
        let indirect = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        for direction in [UISwipeGestureRecognizer.Direction.up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            swipe.allowedTouchTypes = indirect
            view.addGestureRecognizer(swipe)
        }
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        longPress.minimumPressDuration = 0.8
        view.addGestureRecognizer(longPress)
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard !overlayNeedsFocus else { return }
        handleVertical(up: gesture.direction == .up)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, !overlayNeedsFocus, let channel = controller.displayedChannel else { return }
        app.toggleFavorite(channel)
        controller.showToast(app.isFavorite(channel) ? "Ajoutée aux favoris" : "Retirée des favoris")
        longPressConsumedSelect = true
    }

    private var longPressConsumedSelect = false

    private func handleVertical(up: Bool) {
        if !controller.isLive {
            controller.panel = .transport
            return
        }
        // ▲ = chaîne précédente dans la liste (convention « liste qui défile »), inversable.
        let offset = (up ? -1 : 1) * (app.settings.invertZapDirection ? -1 : 1)
        controller.zap(by: offset)
    }

    // MARK: Télécommande

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !overlayNeedsFocus, let press = presses.first else {
            super.pressesBegan(presses, with: event)
            return
        }
        switch press.type {
        case .upArrow, .downArrow, .leftArrow, .rightArrow, .menu, .playPause, .select:
            // Traité à la fin de l'appui (permet l'appui long sur « select »).
            break
        default:
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !overlayNeedsFocus, let press = presses.first else {
            if presses.first?.type == .menu, controller.panel != .none {
                controller.panel = .none
                return
            }
            super.pressesEnded(presses, with: event)
            return
        }
        switch press.type {
        case .upArrow:
            handleVertical(up: true)
        case .downArrow:
            handleVertical(up: false)
        case .leftArrow:
            if controller.isLive { controller.panel = .channels } else { controller.seekArchive(by: -30) }
        case .rightArrow:
            if controller.isLive { controller.panel = .programmes } else { controller.seekArchive(by: 30) }
        case .select:
            if longPressConsumedSelect { longPressConsumedSelect = false; return }
            // Clic central : commandes (informations + boutons ronds), comme le reste de tvOS.
            controller.panel = controller.isLive ? .controls : .transport
        case .playPause:
            controller.togglePlayPause()
            controller.showBanner()
        case .menu:
            if controller.bannerVisible {
                controller.hideOverlays()
            } else {
                dismissPlayer()
            }
        default:
            super.pressesEnded(presses, with: event)
        }
    }

    private func dismissPlayer() {
        observing = false
        controller.close()
        onDismiss()
    }
}

/// Pont SwiftUI → lecteur UIKit.
struct PlayerScreen: UIViewControllerRepresentable {
    let app: AppModel
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> PlayerViewController {
        PlayerViewController(app: app, onDismiss: onDismiss)
    }

    func updateUIViewController(_ controller: PlayerViewController, context: Context) {}
}
