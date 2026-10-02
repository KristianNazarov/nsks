import Foundation

/// Physical QWERTY ↔ ЙЦУКЕН mapping matching standard macOS Russian layout.
public struct RussianEnglishLayout: KeyboardLayoutMapping, Sendable {
    public let source: KeyboardLayoutID
    public let target: KeyboardLayoutID

    private let map: [Character: Character]

    public static let englishToRussian = RussianEnglishLayout(
        source: .english,
        target: .russian,
        map: Self.enToRu
    )

    public static let russianToEnglish = RussianEnglishLayout(
        source: .russian,
        target: .english,
        map: Self.ruToEn
    )

    private init(source: KeyboardLayoutID, target: KeyboardLayoutID, map: [Character: Character]) {
        self.source = source
        self.target = target
        self.map = map
    }

    public func convertCharacter(_ character: Character) -> Character? {
        if let mapped = map[character] {
            return mapped
        }
        // Preserve characters that exist unchanged in both layouts (digits, some punctuation).
        if Self.passthrough.contains(character) {
            return character
        }
        return nil
    }

    // MARK: - Maps

    /// Lowercase EN → RU for the same physical key on macOS Russian phonetic layout (ЙЦУКЕН).
    private static let enToRuLower: [Character: Character] = [
        "`": "ё",
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г", "i": "ш", "o": "щ", "p": "з",
        "[": "х", "]": "ъ",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р", "j": "о", "k": "л", "l": "д",
        ";": "ж", "'": "э",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь",
        ",": "б", ".": "ю", "/": "."
    ]

    private static let enToRuUpper: [Character: Character] = [
        "~": "Ё",
        "Q": "Й", "W": "Ц", "E": "У", "R": "К", "T": "Е", "Y": "Н", "U": "Г", "I": "Ш", "O": "Щ", "P": "З",
        "{": "Х", "}": "Ъ",
        "A": "Ф", "S": "Ы", "D": "В", "F": "А", "G": "П", "H": "Р", "J": "О", "K": "Л", "L": "Д",
        ":": "Ж", "\"": "Э",
        "Z": "Я", "X": "Ч", "C": "С", "V": "М", "B": "И", "N": "Т", "M": "Ь",
        "<": "Б", ">": "Ю", "?": ","
    ]

    /// Shift+number row on macOS (EN QWERTY ↔ RU ЙЦУКЕН). Keys 5/8/9/0 and `!` are unchanged.
    private static let enToRuNumberRowShift: [Character: Character] = [
        "@": "\"",
        "#": "№",
        "$": ";",
        "^": ":",
        "&": "?"
    ]

    private static let enToRu: [Character: Character] = {
        var result = enToRuLower
        for (k, v) in enToRuUpper { result[k] = v }
        for (k, v) in enToRuNumberRowShift { result[k] = v }
        return result
    }()

    private static let ruToEn: [Character: Character] = {
        var result: [Character: Character] = [:]
        for (k, v) in enToRu {
            result[v] = k
        }
        return result
    }()

    private static let passthrough: Set<Character> = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        " ", "\t", "\n",
        "-", "=", "!", "%", "*", "(", ")",
        "+", "_", "\\", "|"
    ]

    /// All characters that participate in EN↔RU physical-key mapping
    /// (e.g. `[`↔`х`, `,`↔`б`). These must count as word characters for last-word detection.
    public static let layoutWordCharacters: Set<Character> = {
        var chars = Set<Character>()
        for (k, v) in enToRu {
            chars.insert(k)
            chars.insert(v)
        }
        return chars
    }()
}

/// keyCode → (english char, russian char) for extendability.
public enum PhysicalKeyMap {
    /// macOS virtual key codes for letter keys (ANSI).
    public static let keyCodeToLayouts: [UInt16: (en: Character, ru: Character)] = [
        50: ("`", "ё"),
        12: ("q", "й"), 13: ("w", "ц"), 14: ("e", "у"), 15: ("r", "к"), 17: ("t", "е"),
        16: ("y", "н"), 32: ("u", "г"), 34: ("i", "ш"), 31: ("o", "щ"), 35: ("p", "з"),
        33: ("[", "х"), 30: ("]", "ъ"),
        0: ("a", "ф"), 1: ("s", "ы"), 2: ("d", "в"), 3: ("f", "а"), 5: ("g", "п"),
        4: ("h", "р"), 38: ("j", "о"), 40: ("k", "л"), 37: ("l", "д"),
        41: (";", "ж"), 39: ("'", "э"),
        6: ("z", "я"), 7: ("x", "ч"), 8: ("c", "с"), 9: ("v", "м"), 11: ("b", "и"),
        45: ("n", "т"), 46: ("m", "ь"),
        43: (",", "б"), 47: (".", "ю"), 44: ("/", ".")
    ]
}
