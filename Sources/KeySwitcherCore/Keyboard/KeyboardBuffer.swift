import Foundation

/// In-memory ring buffer of recent typed characters for last-word detection.
/// Never persisted. Cleared on invalidation.
public final class KeyboardBuffer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case healthy
        case unreliable
    }

    public private(set) var state: State = .healthy

    private var characters: [Character] = []
    private let capacity: Int
    private let lock = NSLock()

    /// Trailing separators after a word (preserved on switch).
    /// Note: `[` `]` `{` `}` are NOT here — on macOS they are the `х`/`ъ` keys.
    public static let trailingSeparatorCharacters: Set<Character> = [
        " ", "\t",
        ",", ".", ":", ";", "!", "?",
        "…", "«", "»", "\"",
        "(", ")",
        "-", "—", "–"
    ]

    /// Kept for compatibility with event classification.
    public static let separatorCharacters: Set<Character> = trailingSeparatorCharacters

    public init(capacity: Int = 256) {
        self.capacity = max(32, capacity)
    }

    public var isHealthy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .healthy
    }

    /// Snapshot of buffer contents (for diagnostics length only — do not log content).
    public var characterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return characters.count
    }

    public func append(_ character: Character) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .healthy else { return }
        characters.append(character)
        if characters.count > capacity {
            characters.removeFirst(characters.count - capacity)
        }
    }

    public func backspace() {
        lock.lock()
        defer { lock.unlock() }
        guard state == .healthy else { return }
        if !characters.isEmpty {
            characters.removeLast()
        }
    }

    public func invalidate(reason: String = "") {
        lock.lock()
        defer { lock.unlock() }
        characters.removeAll(keepingCapacity: true)
        state = .unreliable
        _ = reason
    }

    public func markHealthy() {
        lock.lock()
        defer { lock.unlock() }
        state = .healthy
    }

    public func resetHealthy() {
        lock.lock()
        defer { lock.unlock() }
        characters.removeAll(keepingCapacity: true)
        state = .healthy
    }

    public func replaceWithTrusted(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        characters = Array(text)
        if characters.count > capacity {
            characters = Array(characters.suffix(capacity))
        }
        state = .healthy
    }

    public func lastWord() -> LastWordMatch? {
        lock.lock()
        defer { lock.unlock() }
        guard state == .healthy, !characters.isEmpty else { return nil }

        var idx = characters.count - 1
        var trailing: [Character] = []

        // 1) Trailing sentence punctuation / spaces (e.g. "ghbdtn, ")
        while idx >= 0 && Self.trailingSeparatorCharacters.contains(characters[idx]) {
            trailing.insert(characters[idx], at: 0)
            idx -= 1
        }

        // Lone layout symbols (e.g. `"` instead of `@`) are listed as trailing separators
        // but must still convert when they are the entire buffer.
        if idx < 0, !trailing.isEmpty,
           trailing.allSatisfy({ Self.isWordCharacter($0) }),
           !trailing.contains(where: { $0.isLetter || $0.isNumber }) {
            return LastWordMatch(word: String(trailing), trailingSeparators: "")
        }

        guard idx >= 0 else { return nil }

        // 2) Word body: letters/digits OR layout-mapped keys (`[`↔`х`, etc.)
        var word: [Character] = []
        while idx >= 0 && Self.isWordCharacter(characters[idx]) {
            word.insert(characters[idx], at: 0)
            idx -= 1
        }

        guard !word.isEmpty else { return nil }
        return LastWordMatch(word: String(word), trailingSeparators: String(trailing))
    }

    public static func isWordCharacter(_ ch: Character) -> Bool {
        if ch.isLetter || ch.isNumber { return true }
        if RussianEnglishLayout.layoutWordCharacters.contains(ch) { return true }
        return false
    }

    /// Apply a high-level keyboard event.
    public func apply(_ event: KeyboardEvent) {
        switch event.kind {
        case .character(let ch):
            if Self.separatorCharacters.contains(ch) {
                append(ch)
            } else {
                append(ch)
            }
        case .separator(let ch):
            append(ch)
        case .backspace:
            backspace()
        case .invalidate:
            invalidate()
        }
    }
}
