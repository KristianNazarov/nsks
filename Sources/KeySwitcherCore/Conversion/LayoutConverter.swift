import Foundation

public enum ConversionDirection: Equatable, Sendable {
    case englishToRussian
    case russianToEnglish
}

public struct ConversionResult: Equatable, Sendable {
    public let text: String
    public let direction: ConversionDirection
    public let targetLayout: KeyboardLayoutID

    public init(text: String, direction: ConversionDirection, targetLayout: KeyboardLayoutID) {
        self.text = text
        self.direction = direction
        self.targetLayout = targetLayout
    }
}

public struct LayoutConverter: Sendable {
    private let enToRu: any KeyboardLayoutMapping
    private let ruToEn: any KeyboardLayoutMapping

    public init(
        enToRu: any KeyboardLayoutMapping = RussianEnglishLayout.englishToRussian,
        ruToEn: any KeyboardLayoutMapping = RussianEnglishLayout.russianToEnglish
    ) {
        self.enToRu = enToRu
        self.ruToEn = ruToEn
    }

    /// Convert text, auto-detecting dominant layout of convertible characters.
    public func convert(_ text: String) -> ConversionResult? {
        guard !text.isEmpty else { return nil }

        let enCount = countConvertible(text, using: enToRu)
        let ruCount = countConvertible(text, using: ruToEn)

        if enCount == 0 && ruCount == 0 {
            return nil
        }

        // Prefer the layout with more convertible characters.
        // Tie-breaker: if equal, prefer EN→RU when any Latin letter present.
        let direction: ConversionDirection
        if enCount > ruCount {
            direction = .englishToRussian
        } else if ruCount > enCount {
            direction = .russianToEnglish
        } else if text.contains(where: { $0.isASCII && $0.isLetter }) {
            direction = .englishToRussian
        } else {
            direction = .russianToEnglish
        }

        return convert(text, direction: direction)
    }

    public func convert(_ text: String, direction: ConversionDirection) -> ConversionResult? {
        let mapping: any KeyboardLayoutMapping
        let target: KeyboardLayoutID
        switch direction {
        case .englishToRussian:
            mapping = enToRu
            target = .russian
        case .russianToEnglish:
            mapping = ruToEn
            target = .english
        }

        var output = String()
        output.reserveCapacity(text.count)
        var convertedAny = false

        for ch in text {
            if let mapped = mapping.convertCharacter(ch) {
                output.append(mapped)
                if mapped != ch {
                    convertedAny = true
                } else {
                    // passthrough still "ok"
                }
            } else {
                // Unknown character — keep as-is
                output.append(ch)
            }
        }

        // Require at least one real mapping change OR all chars were convertible/passthrough
        // For words like "ghbdtn" every char maps.
        let hadMappable = text.contains { mapping.convertCharacter($0) != nil }
        guard hadMappable || convertedAny else { return nil }

        return ConversionResult(text: output, direction: direction, targetLayout: target)
    }

    private func countConvertible(_ text: String, using mapping: any KeyboardLayoutMapping) -> Int {
        text.reduce(0) { count, ch in
            guard let mapped = mapping.convertCharacter(ch) else { return count }
            // Count only when it actually changes (not passthrough digits/space)
            return mapped != ch ? count + 1 : count
        }
    }
}
