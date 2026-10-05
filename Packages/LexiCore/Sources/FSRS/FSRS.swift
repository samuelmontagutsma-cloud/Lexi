// FSRS-6 scheduler. Port of py-fsrs (MIT, open-spaced-repetition/py-fsrs, v6.x).
// Verified against reference outputs from py-fsrs in CI (Tests/FSRSTests).
import Foundation

public enum Rating: Int, Codable, CaseIterable, Sendable {
    case again = 1, hard = 2, good = 3, easy = 4
}

public enum CardState: Int, Codable, Sendable {
    case learning = 1, review = 2, relearning = 3
}

public struct FSRSCard: Codable, Equatable, Sendable {
    public var state: CardState = .learning
    public var step: Int? = 0
    public var stability: Double?
    public var difficulty: Double?
    public var due: Date
    public var lastReview: Date?
    public var reps: Int = 0
    public var lapses: Int = 0

    public init(due: Date = Date()) { self.due = due }
}

public struct FSRSParameters: Codable, Equatable, Sendable {
    public static let defaultWeights: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001,
        1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014,
        1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]
    public var w: [Double] = defaultWeights
    public var desiredRetention: Double = 0.90
    public var learningSteps: [TimeInterval] = [60, 600]   // 1 min, 10 min
    public var relearningSteps: [TimeInterval] = [600]     // 10 min
    public var maximumInterval: Int = 36_500                // days
    public var enableFuzzing: Bool = true

    public init() {}
}

public struct FSRS: Sendable {
    public static let stabilityMin = 0.001
    public static let minDifficulty = 1.0
    public static let maxDifficulty = 10.0

    public let p: FSRSParameters
    let decay: Double
    let factor: Double

    public init(parameters: FSRSParameters = FSRSParameters()) {
        precondition(parameters.w.count == 21, "FSRS-6 needs 21 weights")
        precondition((0.0..<1.0).contains(parameters.desiredRetention))
        p = parameters
        decay = -parameters.w[20]
        factor = pow(0.9, 1.0 / decay) - 1.0
    }

    // MARK: public API

    /// Probability of recall at `date` (0 for a card never reviewed).
    public func retrievability(_ card: FSRSCard, at date: Date) -> Double {
        guard let last = card.lastReview, let s = card.stability else { return 0 }
        let elapsed = max(0, Self.wholeDays(from: last, to: date))
        return pow(1.0 + factor * Double(elapsed) / s, decay)
    }

    /// Apply one review. `random` is used only for interval fuzzing.
    public func review(_ input: FSRSCard, rating: Rating, at now: Date,
                       random: () -> Double = { Double.random(in: 0..<1) }) -> FSRSCard {
        var card = input
        let daysSince: Int? = card.lastReview.map { Self.wholeDays(from: $0, to: now) }
        var interval: TimeInterval = 0   // seconds
        var intervalDays: Int? = nil     // set when scheduling in days (fuzz applies)

        if card.state == .review, rating == .again { card.lapses += 1 }

        // 1) memory state
        if card.stability == nil || card.difficulty == nil {
            card.stability = initialStability(rating)
            card.difficulty = initialDifficulty(rating, clamp: true)
        } else {
            let s = card.stability!, d = card.difficulty!
            if let ds = daysSince, ds < 1 {
                card.stability = shortTermStability(s, rating)
            } else {
                let r = retrievability(card, at: now)
                card.stability = rating == .again
                    ? nextForgetStability(d, s, r)
                    : nextRecallStability(d, s, r, rating)
            }
            card.difficulty = nextDifficulty(d, rating)
        }

        // 2) state machine + interval
        switch card.state {
        case .learning, .relearning:
            let steps = card.state == .learning ? p.learningSteps : p.relearningSteps
            let step = card.step ?? 0
            if steps.isEmpty || (step >= steps.count && rating != .again) {
                card.state = .review; card.step = nil
                intervalDays = nextIntervalDays(card.stability!)
            } else {
                switch rating {
                case .again:
                    card.step = 0
                    interval = steps[0]
                case .hard:
                    if step == 0 && steps.count == 1 { interval = steps[0] * 1.5 }
                    else if step == 0 && steps.count >= 2 { interval = (steps[0] + steps[1]) / 2.0 }
                    else { interval = steps[step] }
                case .good:
                    if step + 1 == steps.count {
                        card.state = .review; card.step = nil
                        intervalDays = nextIntervalDays(card.stability!)
                    } else {
                        card.step = step + 1
                        interval = steps[step + 1]
                    }
                case .easy:
                    card.state = .review; card.step = nil
                    intervalDays = nextIntervalDays(card.stability!)
                }
            }
        case .review:
            if rating == .again && !p.relearningSteps.isEmpty {
                card.state = .relearning; card.step = 0
                interval = p.relearningSteps[0]
            } else {
                intervalDays = nextIntervalDays(card.stability!)
            }
        }

        if var days = intervalDays {
            if p.enableFuzzing && card.state == .review { days = fuzzed(days, random: random) }
            interval = TimeInterval(days) * 86_400
        }
        card.due = now.addingTimeInterval(interval)
        card.lastReview = now
        card.reps += 1
        return card
    }

    // MARK: model (FSRS-6)

    func initialStability(_ g: Rating) -> Double {
        max(p.w[g.rawValue - 1], Self.stabilityMin)
    }

    func initialDifficulty(_ g: Rating, clamp: Bool) -> Double {
        let d = p.w[4] - exp(p.w[5] * Double(g.rawValue - 1)) + 1.0
        return clamp ? Self.clampD(d) : d
    }

    func nextDifficulty(_ d: Double, _ g: Rating) -> Double {
        let delta = -p.w[6] * (Double(g.rawValue) - 3.0)
        let damped = d + (10.0 - d) * delta / 9.0                       // linear damping
        let target = initialDifficulty(.easy, clamp: false)
        return Self.clampD(p.w[7] * target + (1.0 - p.w[7]) * damped)   // mean reversion
    }

    func shortTermStability(_ s: Double, _ g: Rating) -> Double {
        var inc = exp(p.w[17] * (Double(g.rawValue) - 3.0 + p.w[18])) * pow(s, -p.w[19])
        if g == .good || g == .easy { inc = max(inc, 1.0) }
        return Self.clampS(s * inc)
    }

    func nextRecallStability(_ d: Double, _ s: Double, _ r: Double, _ g: Rating) -> Double {
        let hardPenalty = g == .hard ? p.w[15] : 1.0
        let easyBonus = g == .easy ? p.w[16] : 1.0
        let inc = exp(p.w[8]) * (11.0 - d) * pow(s, -p.w[9]) * (exp((1.0 - r) * p.w[10]) - 1.0)
        return Self.clampS(s * (1.0 + inc * hardPenalty * easyBonus))
    }

    func nextForgetStability(_ d: Double, _ s: Double, _ r: Double) -> Double {
        let longTerm = p.w[11] * pow(d, -p.w[12]) * (pow(s + 1.0, p.w[13]) - 1.0) * exp((1.0 - r) * p.w[14])
        let shortTerm = s / exp(p.w[17] * p.w[18])
        return Self.clampS(min(longTerm, shortTerm))
    }

    func nextIntervalDays(_ s: Double) -> Int {
        let raw = (s / factor) * (pow(p.desiredRetention, 1.0 / decay) - 1.0)
        let rounded = Int(raw.rounded(.toNearestOrEven))   // matches Python round()
        return min(max(rounded, 1), p.maximumInterval)
    }

    /// py-fsrs fuzz: ±5-15% depending on interval length; never below 2 days.
    func fuzzed(_ days: Int, random: () -> Double) -> Int {
        let ivl = Double(days)
        if ivl < 2.5 { return days }
        let ranges: [(Double, Double, Double)] = [(2.5, 7.0, 0.15), (7.0, 20.0, 0.1), (20.0, .infinity, 0.05)]
        var delta = 1.0
        for (start, end, f) in ranges { delta += f * max(min(ivl, end) - start, 0.0) }
        var minIvl = max(2, Int((ivl - delta).rounded(.toNearestOrEven)))
        let maxIvl = min(Int((ivl + delta).rounded(.toNearestOrEven)), p.maximumInterval)
        minIvl = min(minIvl, maxIvl)
        let f = random() * Double(maxIvl - minIvl + 1) + Double(minIvl)
        return min(Int(f.rounded(.toNearestOrEven)), p.maximumInterval)
    }

    // MARK: helpers

    static func clampD(_ d: Double) -> Double { min(max(d, minDifficulty), maxDifficulty) }
    static func clampS(_ s: Double) -> Double { max(s, stabilityMin) }

    /// Python `timedelta.days`: floor of elapsed seconds / 86400.
    static func wholeDays(from a: Date, to b: Date) -> Int {
        Int((b.timeIntervalSince(a) / 86_400).rounded(.down))
    }
}
