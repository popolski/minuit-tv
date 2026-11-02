import Foundation
import XCTest
@testable import MinuitCore

final class PresentationTests: XCTestCase {
    func testGreeting() {
        XCTAssertEqual(Greeting.text(for: utc("2026-11-02 08:00"), timeZone: paris), "Bonjour")        // 09:00
        XCTAssertEqual(Greeting.text(for: utc("2026-11-02 13:00"), timeZone: paris), "Bon après-midi") // 14:00
        XCTAssertEqual(Greeting.text(for: utc("2026-11-02 19:30"), timeZone: paris), "Bonsoir")        // 20:30
        XCTAssertEqual(Greeting.text(for: utc("2026-11-02 23:30"), timeZone: paris), "Bonne nuit")     // 00:30
    }

    func testQualityBadge() {
        XCTAssertEqual(QualityBadge.parse("FR: TF1 FHD"), .fhd)
        XCTAssertEqual(QualityBadge.parse("Canal+ 4K"), .uhd)
        XCTAssertEqual(QualityBadge.parse("beIN SPORTS 1 ᴴᴰ"), .hd)
        XCTAssertEqual(QualityBadge.parse("Arte UHD HDR"), .uhd)
        XCTAssertEqual(QualityBadge.parse("France 2 (1080p)"), .fhd)
        XCTAssertEqual(QualityBadge.parse("M6 SD"), .sd)
        XCTAssertNil(QualityBadge.parse("HDTV Chill"), "« HDTV » n'est pas un marqueur isolé")
        XCTAssertNil(QualityBadge.parse("Shadow"))
        XCTAssertNil(QualityBadge.parse("France 5"))
    }

    func testLogoTileStyle() {
        let red = LogoTile.RGB(r: 0.8, g: 0.1, b: 0.1)
        XCTAssertEqual(LogoTile.style(for: .init(edgeOpacity: 1, edgeColor: red, edgeVariance: 0.02, contentLuminance: 0.4)), .solid(red))
        // Bords opaques mais hétérogènes (photo) : on ne prolonge pas.
        XCTAssertEqual(LogoTile.style(for: .init(edgeOpacity: 1, edgeColor: red, edgeVariance: 0.3, contentLuminance: 0.3)), .light)
        // Logo détouré blanc : tuile sombre ; logo détouré sombre : tuile claire.
        XCTAssertEqual(LogoTile.style(for: .init(edgeOpacity: 0.1, edgeColor: red, edgeVariance: 0, contentLuminance: 0.9)), .dark)
        XCTAssertEqual(LogoTile.style(for: .init(edgeOpacity: 0, edgeColor: red, edgeVariance: 0, contentLuminance: 0.2)), .light)
        XCTAssertEqual(LogoTile.RGB(r: 1, g: 1, b: 1).luminance, 1, accuracy: 0.0001)
    }
}
