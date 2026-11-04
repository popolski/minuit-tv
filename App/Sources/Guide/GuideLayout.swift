import UIKit
import MinuitCore

/// Source de géométrie de la grille, fournie par le contrôleur.
@MainActor
protocol GuideLayoutDataSource: AnyObject {
    var timeline: GuideTimeline { get }
    var rowCount: Int { get }
    /// Spans horizontaux (x, largeur, en points de la frise) des cases d'une ligne.
    func spans(forRow row: Int) -> [(x: Double, width: Double)]
}

/// Mise en page de la grille : chaînes en lignes, temps en colonnes.
/// Seules les lignes et cases intersectant la zone visible sont calculées.
final class GuideLayout: UICollectionViewLayout {
    static let channelHeaderKind = "channelHeader"
    static let timeHeaderKind = "timeHeader"
    static let nowLineKind = "nowLine"

    weak var dataSource: GuideLayoutDataSource?

    let rowHeight: CGFloat = 92
    let rowSpacing: CGFloat = 8
    let channelColumnWidth: CGFloat = 210
    let timeHeaderHeight: CGFloat = 64
    let itemGap: CGFloat = 6

    private var cachedSpans: [Int: [(x: Double, width: Double)]] = [:]

    override func prepare() {
        super.prepare()
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        if context.invalidateEverything || context.invalidateDataSourceCounts { cachedSpans.removeAll() }
        super.invalidateLayout(with: context)
    }

    func invalidateRows() { cachedSpans.removeAll() }

    private func spans(_ row: Int) -> [(x: Double, width: Double)] {
        if let cached = cachedSpans[row] { return cached }
        let value = dataSource?.spans(forRow: row) ?? []
        cachedSpans[row] = value
        return value
    }

    override var collectionViewContentSize: CGSize {
        guard let dataSource else { return .zero }
        let width = channelColumnWidth + CGFloat(dataSource.timeline.totalWidth) + 80
        let height = timeHeaderHeight + CGFloat(dataSource.rowCount) * (rowHeight + rowSpacing) + 60
        return CGSize(width: width, height: height)
    }

    func rowY(_ row: Int) -> CGFloat { timeHeaderHeight + CGFloat(row) * (rowHeight + rowSpacing) }

    func x(for date: Date) -> CGFloat {
        guard let timeline = dataSource?.timeline else { return 0 }
        return channelColumnWidth + CGFloat(timeline.x(for: date))
    }

    private func visibleRows(in rect: CGRect) -> Range<Int> {
        guard let count = dataSource?.rowCount, count > 0 else { return 0..<0 }
        let stride = rowHeight + rowSpacing
        let first = max(0, Int((rect.minY - timeHeaderHeight) / stride))
        let last = min(count - 1, Int((rect.maxY - timeHeaderHeight) / stride))
        return first <= last ? first..<(last + 1) : 0..<0
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let collectionView else { return nil }
        var result: [UICollectionViewLayoutAttributes] = []
        let offset = collectionView.contentOffset
        for row in visibleRows(in: rect) {
            let rowSpans = spans(row)
            for (index, span) in rowSpans.enumerated() {
                let minX = channelColumnWidth + CGFloat(span.x)
                let maxX = minX + CGFloat(span.width)
                if maxX < rect.minX || minX > rect.maxX { continue }
                if let attributes = layoutAttributesForItem(at: IndexPath(item: index, section: row)) {
                    result.append(attributes)
                }
            }
            let header = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.channelHeaderKind, with: IndexPath(item: 0, section: row))
            header.frame = CGRect(x: offset.x, y: rowY(row), width: channelColumnWidth - 12, height: rowHeight)
            header.zIndex = 20
            result.append(header)
        }
        let time = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.timeHeaderKind, with: IndexPath(item: 0, section: 0))
        time.frame = CGRect(x: offset.x, y: offset.y, width: collectionView.bounds.width, height: timeHeaderHeight)
        time.zIndex = 30
        result.append(time)

        let nowX = x(for: Date())
        let now = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.nowLineKind, with: IndexPath(item: 0, section: 0))
        now.frame = CGRect(x: nowX - 2, y: offset.y + timeHeaderHeight - 10, width: 4, height: collectionView.bounds.height)
        now.zIndex = 25
        now.isHidden = nowX < offset.x + channelColumnWidth
        result.append(now)
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let rowSpans = spans(indexPath.section)
        guard rowSpans.indices.contains(indexPath.item) else { return nil }
        let span = rowSpans[indexPath.item]
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = CGRect(x: channelColumnWidth + CGFloat(span.x), y: rowY(indexPath.section),
                                  width: max(24, CGFloat(span.width) - itemGap), height: rowHeight)
        attributes.zIndex = 1
        return attributes
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        layoutAttributesForElements(in: collectionView?.bounds ?? .zero)?.first {
            $0.representedElementKind == elementKind && $0.indexPath == indexPath
        }
    }

    /// Colonnes et en-têtes collants : recalcul à chaque défilement.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }
}
