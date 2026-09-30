import Foundation

public protocol CaseConversionStrategy: Sendable {
    func nextCase(for text: String) -> String
}

/// Cycles: lower → UPPER → Title → lower
public struct CyclicCaseStrategy: CaseConversionStrategy {
    public init() {}

    public func nextCase(for text: String) -> String {
        guard !text.isEmpty else { return text }

        if isAllLower(text) {
            return text.uppercased()
        }
        if isAllUpper(text) {
            return toTitleCase(text)
        }
        if isTitleCase(text) {
            return text.lowercased()
        }
        // Mixed / unknown → uppercase as a predictable next step
        return text.uppercased()
    }

    private func letters(in text: String) -> [Character] {
        text.filter { $0.isLetter }
    }

    private func isAllLower(_ text: String) -> Bool {
        let ls = letters(in: text)
        guard !ls.isEmpty else { return false }
        return ls.allSatisfy { String($0) == String($0).lowercased() }
    }

    private func isAllUpper(_ text: String) -> Bool {
        let ls = letters(in: text)
        guard !ls.isEmpty else { return false }
        return ls.allSatisfy { String($0) == String($0).uppercased() }
    }

    private func isTitleCase(_ text: String) -> Bool {
        toTitleCase(text) == text && !isAllUpper(text) && !isAllLower(text)
    }

    private func toTitleCase(_ text: String) -> String {
        var result = ""
        var newWord = true
        for ch in text {
            if ch.isLetter {
                if newWord {
                    result += String(ch).uppercased()
                    newWord = false
                } else {
                    result += String(ch).lowercased()
                }
            } else {
                result.append(ch)
                newWord = ch.isWhitespace || ch == "-" || ch == "_"
            }
        }
        return result
    }
}

public struct CaseConverter: Sendable {
    private let strategy: any CaseConversionStrategy

    public init(strategy: any CaseConversionStrategy = CyclicCaseStrategy()) {
        self.strategy = strategy
    }

    public func convert(_ text: String) -> String {
        strategy.nextCase(for: text)
    }
}
