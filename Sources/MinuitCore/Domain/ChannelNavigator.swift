import Foundation

/// Navigation de zapping dans une liste ordonnée : suivante, précédente (en boucle),
/// rappel de la chaîne précédente, saisie numérique.
public struct ChannelNavigator: Sendable, Equatable {
    public private(set) var list: [ChannelID]
    public private(set) var context: ChannelListContext
    public private(set) var current: ChannelID?
    /// Chaîne regardée juste avant (touche « rappel »).
    public private(set) var previous: ChannelID?

    public init(list: [ChannelID], context: ChannelListContext, current: ChannelID? = nil) {
        self.list = list
        self.context = context
        self.current = current
    }

    public mutating func setList(_ list: [ChannelID], context: ChannelListContext) {
        self.list = list
        self.context = context
    }

    /// Chaîne à `offset` positions de la chaîne courante, en boucle.
    /// Si la chaîne courante n'appartient pas à la liste, on part du début.
    public func neighbour(offset: Int) -> ChannelID? {
        guard !list.isEmpty else { return nil }
        guard let current, let index = list.firstIndex(of: current) else {
            return offset >= 0 ? list.first : list.last
        }
        let count = list.count
        let target = ((index + offset) % count + count) % count
        return list[target]
    }

    public mutating func tune(_ id: ChannelID) {
        guard id != current else { return }
        previous = current
        current = id
    }

    @discardableResult
    public mutating func step(_ offset: Int) -> ChannelID? {
        guard let target = neighbour(offset: offset) else { return nil }
        tune(target)
        return target
    }

    @discardableResult
    public mutating func recall() -> ChannelID? {
        guard let previous else { return nil }
        tune(previous)
        return previous
    }

    /// Résout une saisie numérique (numéro logique serveur, sinon position 1-based dans la liste).
    public static func resolve(number: Int, in channels: [Channel]) -> ChannelID? {
        if let match = channels.first(where: { $0.number == number }) { return match.id }
        guard number >= 1, number <= channels.count else { return nil }
        return channels[number - 1].id
    }
}
