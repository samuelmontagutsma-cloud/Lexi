import Foundation
import FSRS

/// Maps a game answer to an FSRS rating.
/// wrong → Again; correct and slow → Hard; correct → Good; correct and fast → Easy.
/// A hint or a second try caps the rating at Hard.
public enum GameKind: String, Codable, CaseIterable, Sendable {
    case wordToMeaning, meaningToWord, matching, spelling, listening, fillBlank, toneTrainer, flashcard
}

public struct GradeThresholds: Equatable, Sendable {
    /// Seconds. At or below `fast` → Easy. Above `slow` → Hard.
    public let fast: Double
    public let slow: Double

    public init(fast: Double, slow: Double) {
        precondition(fast < slow)
        self.fast = fast
        self.slow = slow
    }

    /// Base values per game. Spelling scales with answer length (typing time ≈ 0.35 s/char fast, 1 s/char slow).
    public static func forGame(_ kind: GameKind, answerLength: Int = 0) -> GradeThresholds {
        let n = Double(max(0, answerLength))
        switch kind {
        case .wordToMeaning, .meaningToWord: return .init(fast: 2.5, slow: 8)
        case .matching: return .init(fast: 3, slow: 8)          // per pair
        case .listening, .toneTrainer: return .init(fast: 3, slow: 9)
        case .fillBlank: return .init(fast: 4, slow: 12)
        case .spelling: return .init(fast: 1.5 + 0.35 * n, slow: 6 + 1.0 * n)
        case .flashcard: return .init(fast: 2, slow: 10)
        }
    }
}

public enum Grader {
    public static func rating(correct: Bool, seconds: Double, thresholds: GradeThresholds,
                              usedHint: Bool = false) -> Rating {
        guard correct else { return .again }
        let base: Rating
        if seconds <= thresholds.fast { base = .easy }
        else if seconds > thresholds.slow { base = .hard }
        else { base = .good }
        if usedHint { return base == .again ? .again : .hard }
        return base
    }

    public static func rating(kind: GameKind, correct: Bool, seconds: Double, answerLength: Int = 0,
                              usedHint: Bool = false) -> Rating {
        rating(correct: correct, seconds: seconds,
               thresholds: .forGame(kind, answerLength: answerLength), usedHint: usedHint)
    }
}
