import XCTest

/// Tests d'interface tvOS sur simulateur, en mode démonstration (`-uitest`) :
/// serveur Xtream simulé, vidéo locale. Ils vérifient la navigation au focus et que
/// l'application ne se ferme pas sur les parcours principaux. Ils ne prouvent rien sur
/// le rendu vidéo réel : le simulateur n'est pas une Apple TV.
///
/// Les lignes « [MINUIT-UITEST] » sont reprises dans le journal de la CI.
@MainActor
final class MinuitUITests: XCTestCase {
    private var app: XCUIApplication!
    private var remote: XCUIRemote { XCUIRemote.shared }

    override nonisolated func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-uitest"] + extra
        app.launch()
    }

    private var focused: XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func focusedID() -> String {
        let element = focused
        return element.exists ? (element.identifier.isEmpty ? "«\(element.label)»" : element.identifier) : "<aucun>"
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times {
            remote.press(button)
            Thread.sleep(forTimeInterval: 0.45)
        }
    }

    private func log(_ message: String) {
        print("[MINUIT-UITEST] \(name) — \(message)")
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertRunning(_ step: String) {
        let state = app.state
        log("après « \(step) » : état \(state.rawValue), focus \(state == .runningForeground ? focusedID() : "-")")
        XCTAssertEqual(state, .runningForeground, "L'application s'est fermée : \(step)")
    }

    /// Vérifie qu'un élément est réellement dans l'écran (le focus seul ne le prouve pas).
    private func assertOnScreen(_ element: XCUIElement, _ what: String) {
        let screen = app.windows.firstMatch.frame
        let frame = element.frame
        log("\(what) : cadre \(frame), écran \(screen)")
        XCTAssertTrue(screen.contains(frame), "\(what) hors de l'écran : \(frame)")
    }

    private func waitForCatalog() {
        // Liste des chaînes, ou grille « À l'antenne » sur un appareil déjà utilisé.
        let list = app.descendants(matching: .any)["channel-101"]
        let onAir = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'onair-'")).firstMatch
        let deadline = Date().addingTimeInterval(30)
        while !list.exists && !onAir.exists && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(list.exists || onAir.exists, "catalogue de démonstration absent")
    }

    /// Descend dans la barre latérale, choisit « Toutes les chaînes », puis va à droite
    /// jusqu'à la liste des chaînes.
    private func focusChannelList() {
        var n = 0
        while focusedID().hasPrefix("nav-") && n < 3 { press(.down); n += 1 }
        n = 0
        while focusedID() != "sidebar-Toutes les chaînes" && n < 4 {
            press(focusedID() == "sidebar-À l'antenne" || focusedID().hasPrefix("nav-") ? .down : .up)
            n += 1
        }
        Thread.sleep(forTimeInterval: 0.5)
        n = 0
        while !focusedID().hasPrefix("channel-") && n < 4 { press(.right); n += 1 }
        log("focus dans la liste : \(focusedID())")
        XCTAssertTrue(focusedID().hasPrefix("channel-"), "impossible d'atteindre la liste des chaînes")
    }

    func testLaunchLandsOnMenu() {
        launch()
        waitForCatalog()
        Thread.sleep(forTimeInterval: 1)
        log("focus au lancement : \(focusedID())")
        screenshot("01-lancement")
        XCTAssertTrue(focusedID().hasPrefix("nav-"), "au lancement, le focus doit être sur la capsule de navigation")
        assertOnScreen(app.buttons["nav-live"], "capsule de navigation au lancement")
    }

    func testOpenChannelAndUseControls() {
        launch()
        waitForCatalog()
        focusChannelList()
        screenshot("02-liste")
        press(.select)
        Thread.sleep(forTimeInterval: 6)
        assertRunning("ouverture d'une chaîne (clic central)")
        screenshot("03-lecteur")
        press(.select)
        Thread.sleep(forTimeInterval: 2)
        assertRunning("commandes du lecteur (clic central)")
        screenshot("04-commandes")
        press(.right)
        assertRunning("déplacement dans les commandes")
        press(.menu)
        Thread.sleep(forTimeInterval: 1)
        assertRunning("fermeture des commandes (Retour)")
        press(.down)
        Thread.sleep(forTimeInterval: 3)
        assertRunning("zapping (▼)")
        press(.menu)
        Thread.sleep(forTimeInterval: 2)
        assertRunning("fermeture du lecteur (Retour)")
        screenshot("05-retour-liste")
    }

    /// Appareil déjà utilisé : la liste démarre sur la dernière chaîne (en bas). La barre du
    /// haut doit rester visible et atteignable.
    func testTopBarStaysVisibleWithScrolledList() {
        launch(["-demoLastChannel"])
        waitForCatalog()
        Thread.sleep(forTimeInterval: 1)
        screenshot("06-lancement-appareil-utilise")
        focusChannelList()
        var n = 0
        while focusedID() != "channel-501" && n < 12 { press(.down); n += 1 }
        Thread.sleep(forTimeInterval: 1)
        let nav = app.buttons["nav-live"]
        log("barre du haut : existe \(nav.exists), cadre \(nav.frame), focus \(focusedID())")
        screenshot("07-liste-defilee")
        XCTAssertTrue(nav.exists, "la capsule de navigation doit exister")
        assertOnScreen(nav, "capsule de navigation, liste défilée")
        press(.menu)
        press(.menu)
        log("après 2 × Retour : focus \(focusedID())")
        screenshot("08-retour-menu")
        XCTAssertTrue(focusedID().hasPrefix("nav-"), "Retour doit mener à la capsule de navigation")
    }

    /// Replay depuis le panneau des programmes (▶), sur une chaîne avec archive.
    func testReplayFromProgrammePanel() {
        launch()
        waitForCatalog()
        focusChannelList()
        press(.select)
        Thread.sleep(forTimeInterval: 5)
        assertRunning("ouverture de la chaîne")
        press(.right)
        Thread.sleep(forTimeInterval: 2)
        log("panneau des programmes, focus \(focusedID())")
        screenshot("09-panneau-programmes")
        press(.up)
        press(.select)
        Thread.sleep(forTimeInterval: 7)
        assertRunning("lancement d'un replay")
        screenshot("10-replay")
        press(.select)
        Thread.sleep(forTimeInterval: 1)
        log("barre de transport : badge REPLAY \(app.staticTexts["REPLAY"].exists), focus \(focusedID())")
        screenshot("11-replay-transport")
        XCTAssertTrue(app.staticTexts["REPLAY"].exists, "le replay doit être en cours (badge REPLAY)")
    }

    /// Aperçu vidéo dans la fiche de la chaîne, puis plein écran sans rechargement.
    func testPreviewThenFullScreen() {
        launch()
        waitForCatalog()
        focusChannelList()
        press(.down)
        Thread.sleep(forTimeInterval: 5)
        assertRunning("aperçu vidéo dans la fiche")
        screenshot("13-apercu")
        press(.select)
        Thread.sleep(forTimeInterval: 2)
        assertRunning("passage en plein écran")
        screenshot("14-plein-ecran-depuis-apercu")
        press(.menu)
        Thread.sleep(forTimeInterval: 3)
        assertRunning("retour à la liste")
        screenshot("15-retour-apres-plein-ecran")
    }

    /// « À l'antenne » : grandes cartes des chaînes regardées.
    func testOnAirGrid() {
        launch(["-demoLastChannel"])
        waitForCatalog()
        press(.down)
        Thread.sleep(forTimeInterval: 1)
        log("section au lancement : \(focusedID())")
        press(.right)
        Thread.sleep(forTimeInterval: 2)
        log("focus dans la grille : \(focusedID())")
        screenshot("16-a-l-antenne")
        XCTAssertTrue(focusedID().hasPrefix("onair-"), "la grille « À l'antenne » doit être focalisable")
    }

    /// Écran Diagnostics : mise en page dans l'écran (pas de débordement).
    func testDiagnosticsLayout() {
        launch()
        waitForCatalog()
        press(.right, times: 2)
        log("capsule : \(focusedID())")
        press(.select)
        Thread.sleep(forTimeInterval: 1)
        press(.down)
        var n = 0
        while !focused.label.contains("Diagnostics") && n < 10 { press(.down); n += 1 }
        press(.select)
        Thread.sleep(forTimeInterval: 2)
        assertRunning("ouverture des diagnostics")
        screenshot("12-diagnostics")
        assertOnScreen(app.buttons["nav-settings"], "capsule de navigation sur l'écran Diagnostics")
    }

    func testBackNavigationReachesMenu() {
        launch()
        waitForCatalog()
        focusChannelList()
        press(.menu)
        assertRunning("Retour depuis la liste des chaînes")
        XCTAssertTrue(focusedID().hasPrefix("sidebar-"), "Retour depuis la liste doit ramener aux catégories")
        press(.menu)
        assertRunning("Retour depuis les catégories")
        XCTAssertTrue(focusedID().hasPrefix("nav-"), "Retour depuis les catégories doit ramener au menu")
    }
}
