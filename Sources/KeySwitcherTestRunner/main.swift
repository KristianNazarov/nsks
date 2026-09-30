import Foundation
import KeySwitcherCore

@main
struct TestRunner {
    static var failures = 0

    static func main() {
        testLayoutConverter()
        testKeyboardBuffer()
        testCaseConverter()
        testIntegration()

        if failures == 0 {
            print("✅ All tests passed")
            exit(0)
        } else {
            print("❌ \(failures) test(s) failed")
            exit(1)
        }
    }

    static func expect(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
        if !condition {
            failures += 1
            print("FAIL \(file):\(line) — \(message)")
        }
    }

    static func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #fileID, line: Int = #line) {
        if a != b {
            failures += 1
            print("FAIL \(file):\(line) — expected \(b), got \(a). \(message)")
        }
    }

    static func testLayoutConverter() {
        print("• LayoutConverter")
        let converter = LayoutConverter()

        let r1 = converter.convert("ghbdtn")
        expectEqual(r1?.text, "привет")
        expectEqual(r1?.direction, .englishToRussian)
        expectEqual(r1?.targetLayout, .russian)

        let r2 = converter.convert("руддщ")
        expectEqual(r2?.text, "hello")
        expectEqual(r2?.direction, .russianToEnglish)

        expectEqual(converter.convert("GHBDTN")?.text, "ПРИВЕТ")
        expectEqual(converter.convert("Ghbdtn")?.text, "Привет")
        expectEqual(converter.convert("ghbdtn vbh")?.text, "привет мир")
    }

    static func testKeyboardBuffer() {
        print("• KeyboardBuffer")
        let buffer = KeyboardBuffer()
        for ch in "ghbdtn" { buffer.append(ch) }
        expectEqual(buffer.lastWord()?.word, "ghbdtn")
        expectEqual(buffer.lastWord()?.trailingSeparators, "")

        let buffer2 = KeyboardBuffer()
        for ch in "ghbdtn " { buffer2.append(ch) }
        expectEqual(buffer2.lastWord()?.word, "ghbdtn")
        expectEqual(buffer2.lastWord()?.trailingSeparators, " ")
        expectEqual(buffer2.lastWord()?.deleteCount, 7)

        let buffer3 = KeyboardBuffer()
        for ch in "ghbdtn, " { buffer3.append(ch) }
        expectEqual(buffer3.lastWord()?.word, "ghbdtn")
        expectEqual(buffer3.lastWord()?.trailingSeparators, ", ")

        let buffer4 = KeyboardBuffer()
        for ch in "abc" { buffer4.append(ch) }
        buffer4.backspace()
        expectEqual(buffer4.lastWord()?.word, "ab")

        let buffer5 = KeyboardBuffer()
        for ch in "ghbdtn" { buffer5.append(ch) }
        buffer5.invalidate(reason: "test")
        expect(!buffer5.isHealthy, "should be unreliable")
        expect(buffer5.lastWord() == nil, "no word when unreliable")

        let buffer6 = KeyboardBuffer()
        for ch in "hello world" { buffer6.append(ch) }
        expectEqual(buffer6.lastWord()?.word, "world")

        // х → [ must stay part of the word on reverse conversion
        let buffer7 = KeyboardBuffer()
        for ch in "хлопушек" { buffer7.append(ch) }
        let conv = LayoutConverter()
        let en = conv.convert(buffer7.lastWord()!.word)
        expectEqual(en?.text, "[kjgeitr")
        buffer7.replaceWithTrusted(en!.text)
        expectEqual(buffer7.lastWord()?.word, "[kjgeitr")
        let ru = conv.convert(buffer7.lastWord()!.word)
        expectEqual(ru?.text, "хлопушек")
    }

    static func testCaseConverter() {
        print("• CaseConverter")
        let converter = CaseConverter()
        expectEqual(converter.convert("hello world"), "HELLO WORLD")
        expectEqual(converter.convert("HELLO WORLD"), "Hello World")
        expectEqual(converter.convert("Hello World"), "hello world")

        var text = "hello"
        text = converter.convert(text)
        expectEqual(text, "HELLO")
        text = converter.convert(text)
        expectEqual(text, "Hello")
        text = converter.convert(text)
        expectEqual(text, "hello")

        expectEqual(converter.convert("привет"), "ПРИВЕТ")
    }

    static func testIntegration() {
        print("• Integration last-word + convert")
        let buffer = KeyboardBuffer()
        for ch in "ghbdtn " { buffer.append(ch) }
        guard let match = buffer.lastWord() else {
            expect(false, "expected match")
            return
        }
        let converter = LayoutConverter()
        let converted = converter.convert(match.word)
        expectEqual(converted?.text, "привет")
        let insert = (converted?.text ?? "") + match.trailingSeparators
        expectEqual(insert, "привет ")

        let buffer2 = KeyboardBuffer()
        for ch in "руддщ!" { buffer2.append(ch) }
        guard let match2 = buffer2.lastWord() else {
            expect(false, "expected match2")
            return
        }
        expectEqual(converter.convert(match2.word)?.text, "hello")
        expectEqual(match2.trailingSeparators, "!")
    }
}
