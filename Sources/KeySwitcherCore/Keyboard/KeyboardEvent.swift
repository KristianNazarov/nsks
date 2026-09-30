import Foundation

public struct KeyboardEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case character(Character)
        case backspace
        case separator(Character)
        case invalidate
    }

    public let kind: Kind
    public let keyCode: UInt16
    public let flags: UInt64

    public init(kind: Kind, keyCode: UInt16 = 0, flags: UInt64 = 0) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
    }
}

public struct LastWordMatch: Equatable, Sendable {
    /// The word characters (without trailing separators).
    public let word: String
    /// Separators immediately after the word (spaces, punctuation).
    public let trailingSeparators: String
    /// Total characters to delete from the caret (word + trailing).
    public var deleteCount: Int {
        word.count + trailingSeparators.count
    }

    public init(word: String, trailingSeparators: String) {
        self.word = word
        self.trailingSeparators = trailingSeparators
    }
}
