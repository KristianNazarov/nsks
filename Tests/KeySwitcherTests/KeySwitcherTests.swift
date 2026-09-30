import XCTest
@testable import KeySwitcherCore

final class LayoutConverterTests: XCTestCase {
    private let converter = LayoutConverter()

    func testEnglishToRussianGhbdtn() {
        let result = converter.convert("ghbdtn")
        XCTAssertEqual(result?.text, "привет")
        XCTAssertEqual(result?.direction, .englishToRussian)
        XCTAssertEqual(result?.targetLayout, .russian)
    }

    func testRussianToEnglishHello() {
        let result = converter.convert("руддщ")
        XCTAssertEqual(result?.text, "hello")
        XCTAssertEqual(result?.direction, .russianToEnglish)
        XCTAssertEqual(result?.targetLayout, .english)
    }

    func testUppercaseEnglishToRussian() {
        let result = converter.convert("GHBDTN")
        XCTAssertEqual(result?.text, "ПРИВЕТ")
    }

    func testMixedCase() {
        let result = converter.convert("Ghbdtn")
        XCTAssertEqual(result?.text, "Привет")
    }

    func testTwoWords() {
        let result = converter.convert("ghbdtn vbh")
        XCTAssertEqual(result?.text, "привет мир")
    }

    func testExplicitDirection() {
        let result = converter.convert("ghbdtn", direction: .englishToRussian)
        XCTAssertEqual(result?.text, "привет")
    }
}

final class KeyboardBufferTests: XCTestCase {
    func testLastWordSimple() {
        let buffer = KeyboardBuffer()
        for ch in "ghbdtn" {
            buffer.append(ch)
        }
        let match = buffer.lastWord()
        XCTAssertEqual(match?.word, "ghbdtn")
        XCTAssertEqual(match?.trailingSeparators, "")
        XCTAssertEqual(match?.deleteCount, 6)
    }

    func testLastWordWithTrailingSpace() {
        let buffer = KeyboardBuffer()
        for ch in "ghbdtn " {
            buffer.append(ch)
        }
        let match = buffer.lastWord()
        XCTAssertEqual(match?.word, "ghbdtn")
        XCTAssertEqual(match?.trailingSeparators, " ")
        XCTAssertEqual(match?.deleteCount, 7)
    }

    func testLastWordWithPunctuationAndSpace() {
        let buffer = KeyboardBuffer()
        for ch in "ghbdtn, " {
            buffer.append(ch)
        }
        let match = buffer.lastWord()
        XCTAssertEqual(match?.word, "ghbdtn")
        XCTAssertEqual(match?.trailingSeparators, ", ")
    }

    func testBackspace() {
        let buffer = KeyboardBuffer()
        for ch in "abc" { buffer.append(ch) }
        buffer.backspace()
        XCTAssertEqual(buffer.lastWord()?.word, "ab")
    }

    func testInvalidateMakesUnreliable() {
        let buffer = KeyboardBuffer()
        for ch in "ghbdtn" { buffer.append(ch) }
        buffer.invalidate(reason: "test")
        XCTAssertFalse(buffer.isHealthy)
        XCTAssertNil(buffer.lastWord())
    }

    func testNoWordAfterOnlySeparators() {
        let buffer = KeyboardBuffer()
        buffer.append(" ")
        buffer.append(",")
        XCTAssertNil(buffer.lastWord())
    }

    func testWordAfterPreviousWords() {
        let buffer = KeyboardBuffer()
        for ch in "hello world" { buffer.append(ch) }
        XCTAssertEqual(buffer.lastWord()?.word, "world")
    }
}

final class CaseConverterTests: XCTestCase {
    private let converter = CaseConverter()

    func testLowerToUpper() {
        XCTAssertEqual(converter.convert("hello world"), "HELLO WORLD")
    }

    func testUpperToTitle() {
        XCTAssertEqual(converter.convert("HELLO WORLD"), "Hello World")
    }

    func testTitleToLower() {
        XCTAssertEqual(converter.convert("Hello World"), "hello world")
    }

    func testCycle() {
        var text = "hello"
        text = converter.convert(text)
        XCTAssertEqual(text, "HELLO")
        text = converter.convert(text)
        XCTAssertEqual(text, "Hello")
        text = converter.convert(text)
        XCTAssertEqual(text, "hello")
    }

    func testUnicode() {
        let result = converter.convert("привет")
        XCTAssertEqual(result, "ПРИВЕТ")
    }
}

final class LastWordConversionIntegrationTests: XCTestCase {
    func testWordPlusSpaceConvertsPreservingSpace() {
        let buffer = KeyboardBuffer()
        for ch in "ghbdtn " { buffer.append(ch) }
        guard let match = buffer.lastWord() else {
            return XCTFail("expected match")
        }
        let converter = LayoutConverter()
        let converted = converter.convert(match.word)
        XCTAssertEqual(converted?.text, "привет")
        let insert = (converted?.text ?? "") + match.trailingSeparators
        XCTAssertEqual(insert, "привет ")
    }

    func testWordPlusPunctuation() {
        let buffer = KeyboardBuffer()
        for ch in "руддщ!" { buffer.append(ch) }
        guard let match = buffer.lastWord() else {
            return XCTFail("expected match")
        }
        let converter = LayoutConverter()
        let converted = converter.convert(match.word)
        XCTAssertEqual(converted?.text, "hello")
        XCTAssertEqual(match.trailingSeparators, "!")
    }
}
