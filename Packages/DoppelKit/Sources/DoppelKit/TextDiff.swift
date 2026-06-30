import Foundation

/// One word of a diffed document, flagged if it differs from the other side. The compare view (F8)
/// renders these with changed words highlighted, so a reader sees *why* two files matched — e.g. a
/// contract identical except for the date.
public struct DiffToken: Sendable, Equatable {
    public let text: Substring
    public let changed: Bool
    public init(text: Substring, changed: Bool) {
        self.text = text
        self.changed = changed
    }
}

/// Word-level diff of two normalized texts (space-joined). `left`/`right` are the two documents as
/// token streams; a word present on one side but not the other is `changed`, so a replacement (date
/// swapped) lights up on both panes. ponytail: stdlib `CollectionDifference` over words — no Myers
/// impl, no dependency. Word granularity, not character; good enough for the "changed region" story.
public struct TextDiff: Sendable, Equatable {
    public let left: [DiffToken]
    public let right: [DiffToken]

    public static func compute(_ a: String, _ b: String) -> TextDiff {
        let wa = a.split(separator: " ")
        let wb = b.split(separator: " ")
        var removed = Set<Int>() // offsets into `wa` dropped to reach `wb`
        var inserted = Set<Int>() // offsets into `wb` added
        for change in wb.difference(from: wa) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        let left = wa.enumerated().map { DiffToken(text: $0.element, changed: removed.contains($0.offset)) }
        let right = wb.enumerated().map { DiffToken(text: $0.element, changed: inserted.contains($0.offset)) }
        return TextDiff(left: left, right: right)
    }

    /// True when the two documents are word-for-word identical (nothing highlighted on either side).
    public var isIdentical: Bool {
        !left.contains { $0.changed } && !right.contains { $0.changed }
    }
}
