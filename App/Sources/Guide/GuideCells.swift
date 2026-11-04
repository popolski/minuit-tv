import SwiftUI
import UIKit
import MinuitCore

/// Case de programme. Contenu SwiftUI dans une cellule UIKit (UIHostingConfiguration).
final class ProgrammeCell: UICollectionViewCell {
    static let reuseIdentifier = "programme"

    struct Model: Equatable {
        var title: String
        var timeText: String
        var isNow: Bool
        var isPast: Bool
        var hasReplay: Bool
        var isGap: Bool
        var progress: Double
    }

    private var model: Model?

    func configure(_ model: Model) {
        self.model = model
        render(focused: isFocused)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            self.render(focused: self.isFocused)
        }
    }

    private func render(focused: Bool) {
        guard let model else { return }
        contentConfiguration = UIHostingConfiguration {
            ProgrammeCellContent(model: model, focused: focused)
        }
        .margins(.all, 0)
    }
}

private struct ProgrammeCellContent: View {
    let model: ProgrammeCell.Model
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.isNow { Circle().fill(Theme.Palette.ember).frame(width: 9, height: 9) }
                Text(model.timeText).font(Theme.Typeface.time(19))
                    .foregroundStyle(focused ? Theme.Palette.onFocusSecondary : Theme.Palette.textSecondary)
                if model.hasReplay {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 17))
                        .foregroundStyle(focused ? Theme.Palette.onFocus : Theme.Palette.archive)
                }
            }
            Text(model.title)
                .font(model.isGap ? Theme.Typeface.body(22) : Theme.Typeface.programme(23))
                .foregroundStyle(titleColor)
                .lineLimit(2)
            Spacer(minLength: 0)
            if model.isNow {
                ProgressLine(progress: model.progress, height: 3)
                    .environment(\.onFocusPill, focused)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(fill)
        )
        .shadow(color: focused ? Color.black.opacity(0.35) : .clear, radius: 16, y: 6)
    }

    private var titleColor: Color {
        if focused { return Theme.Palette.onFocus }
        if model.isGap || (model.isPast && !model.hasReplay) { return Theme.Palette.textTertiary }
        return Theme.Palette.textPrimary
    }

    private var fill: Color {
        if focused { return Theme.Palette.focusFill }
        if model.isNow { return Color.white.opacity(0.16) }
        return model.isGap ? Color.white.opacity(0.04) : Theme.Palette.glass
    }
}

/// En-tête de ligne : logo, numéro et nom de la chaîne (collant à gauche).
final class ChannelHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "channelHeader"
    private var hostingView: UIView?

    func configure(channel: Channel, name: String, isFavorite: Bool) {
        hostingView?.removeFromSuperview()
        let view = UIHostingConfiguration {
            HStack(spacing: 16) {
                ChannelLogoView(channel: channel, size: CGSize(width: 100, height: 58))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if let number = channel.number {
                            Text("\(number)").font(Theme.Typeface.time(20)).foregroundStyle(Theme.Palette.textTertiary)
                        }
                        if isFavorite { Image(systemName: "star.fill").font(.system(size: 16)).foregroundStyle(Theme.Palette.moon) }
                    }
                    Text(name).font(Theme.Typeface.label(23)).lineLimit(2).foregroundStyle(Theme.Palette.textPrimary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Palette.night.opacity(0.9))
        }
        .margins(.all, 0)
        .makeContentView()
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
        hostingView = view
    }
}

/// Frise horaire collante en haut. Ses graduations sont recalculées à chaque
/// application d'attributs (la vue suit le défilement horizontal).
final class TimeHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "timeHeader"
    private var labels: [UILabel] = []
    private var timeline: GuideTimeline?
    private var channelColumnWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Theme.Palette.night).withAlphaComponent(0.97)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(timeline: GuideTimeline, channelColumnWidth: CGFloat) {
        self.timeline = timeline
        self.channelColumnWidth = channelColumnWidth
        relayout(offsetX: frame.minX)
    }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        relayout(offsetX: layoutAttributes.frame.minX)
    }

    private func relayout(offsetX: CGFloat) {
        guard let timeline else { return }
        let ticks = timeline.ticks(stepMinutes: 30)
        var index = 0
        for tick in ticks {
            let x = channelColumnWidth + CGFloat(tick.x) - offsetX
            guard x >= channelColumnWidth - 4, x < bounds.width else { continue }
            let label: UILabel
            if index < labels.count {
                label = labels[index]
            } else {
                label = UILabel()
                label.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
                label.textColor = UIColor(Theme.Palette.textSecondary)
                addSubview(label)
                labels.append(label)
            }
            label.isHidden = false
            label.text = tick.label
            label.sizeToFit()
            label.frame.origin = CGPoint(x: x + 6, y: (bounds.height - label.bounds.height) / 2)
            index += 1
        }
        for extra in labels.dropFirst(index) { extra.isHidden = true }
    }
}

/// Ligne « maintenant », couleur braise.
final class NowLineView: UICollectionReusableView {
    static let reuseIdentifier = "nowLine"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Theme.Palette.ember)
        layer.cornerRadius = 2
        layer.shadowColor = UIColor(Theme.Palette.ember).cgColor
        layer.shadowRadius = 8
        layer.shadowOpacity = 0.7
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }
}
