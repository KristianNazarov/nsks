import Foundation

public enum KeyboardLayoutID: String, Codable, CaseIterable, Sendable {
    case english
    case russian
}

public protocol KeyboardLayoutMapping: Sendable {
    var source: KeyboardLayoutID { get }
    var target: KeyboardLayoutID { get }

    /// Convert a character typed under `source` layout to the character
    /// that the same physical key would produce under `target`.
    func convertCharacter(_ character: Character) -> Character?
}

public struct LayoutPair: Sendable {
    public let forward: any KeyboardLayoutMapping
    public let reverse: any KeyboardLayoutMapping

    public init(forward: any KeyboardLayoutMapping, reverse: any KeyboardLayoutMapping) {
        self.forward = forward
        self.reverse = reverse
    }
}
