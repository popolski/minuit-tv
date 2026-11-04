import SwiftUI
import MinuitCore

/// Fiche programme (depuis le guide) : description, disponibilité réelle du replay, actions.
///
/// La fiche est une feuille : le lecteur (plein écran) ne peut s'ouvrir qu'une fois la feuille
/// refermée, sinon tvOS ignore la présentation et la lecture part sans image. L'action choisie
/// est donc remise à l'appelant, qui la lance après la fermeture.
struct ProgrammeDetailView: View {
    enum Choice { case replay, live }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let programme: Programme
    let channel: Channel
    let onChoose: (Choice) -> Void

    var body: some View {
        let now = Date().addingTimeInterval(app.session?.server.clockSkew ?? 0)
        let availability = CatchupEvaluator.evaluate(programme: programme, channel: channel, now: now, settings: app.settings.catchup)
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 20) {
                ChannelLogoView(channel: channel, size: CGSize(width: 240, height: 144))
                Text(app.displayName(channel)).font(Theme.Typeface.label(26)).foregroundStyle(Theme.Palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                Text(DayLabel.label(for: programme.start, relativeTo: Date(), timeZone: .current)
                     + " · \(programme.start.clockText) – \(programme.end.clockText)")
                    .font(Theme.Typeface.time(26)).foregroundStyle(Theme.Palette.textSecondary)
                Text(programme.title).font(Theme.Typeface.display(56)).lineLimit(3)
                if let subtitle = programme.subtitle {
                    Text(subtitle).font(Theme.Typeface.title(30)).foregroundStyle(Theme.Palette.textSecondary)
                }
                if let category = programme.category {
                    Text(category.uppercased()).font(Theme.Typeface.caption()).tracking(1.5).foregroundStyle(Theme.Palette.moon)
                }
                if let summary = programme.summary {
                    Text(summary).font(Theme.Typeface.body(26)).foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                        .lineLimit(8).frame(maxWidth: 1100, alignment: .leading)
                }
                availabilityText(availability)
                HStack(spacing: 30) {
                    if availability.window != nil {
                        Button {
                            onChoose(.replay)
                            dismiss()
                        } label: {
                            Label(programme.isAiring(at: now) ? "Reprendre au début" : "Regarder en replay", systemImage: "play.fill")
                        }
                    }
                    Button {
                        onChoose(.live)
                        dismiss()
                    } label: { Label("Regarder la chaîne en direct", systemImage: "dot.radiowaves.left.and.right") }
                }
                .padding(.top, 12)
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.backdrop.ignoresSafeArea())
    }

    @ViewBuilder private func availabilityText(_ availability: CatchupAvailability) -> some View {
        switch availability {
        case .available(_, let expiresAt):
            Label("Replay annoncé jusqu'au \(expiresAt.formatted(date: .abbreviated, time: .shortened)) · vérifié au lancement",
                  systemImage: "clock.arrow.circlepath")
                .font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.archive)
        case .startOver:
            Label("En cours · reprise depuis le début possible si le fournisseur l'enregistre", systemImage: "backward.end")
                .font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.archive)
        default:
            Text(availability.userLabel).font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.textTertiary)
        }
    }
}
