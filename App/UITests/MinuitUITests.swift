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
        XCTAssertTrue(app.descendants(matching: .any)["channel-101"].waitForExistence(timeout: 30), "catalogue de démonstration absent")
    }

    /// Descend dans le contenu puis va à droite jusqu'à la liste des chaînes.
    private func focusChannelList() {
        var n = 0
        while focusedID().hasPrefix("nav-") && n < 3 { press(.down); n += 1 }
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
