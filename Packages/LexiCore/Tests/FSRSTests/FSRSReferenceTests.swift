import Foundation
import XCTest
@testable import FSRS

/// Compares the Swift port with outputs of the official py-fsrs (tools/fsrs_vectors.py).
final class FSRSReferenceTests: XCTestCase {
    struct Doc: Decodable {
        struct Config: Decodable { let desired_retention: Double; let learning_steps: [Double]; let relearning_steps: [Double] }
        struct Step: Decodable {
            let rating: Int; let at: Double; let r_before: Double; let state: Int; let step: Int?
            let stability: Double; let difficulty: Double; let due: Double
        }
        struct Case: Decodable { let config: String; let steps: [Step] }
        let fsrs_version: String; let weights: [Double]; let configs: [String: Config]; let cases: [Case]
    }

    static func loadVectors() throws -> Doc {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("vectors.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("vectors.json missing: run tools/fsrs_vectors.py (CI does this)")
        }
        return try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url))
    }

    func close(_ a: Double, _ b: Double, tol: Double = 1e-9) -> Bool {
        abs(a - b) <= tol * max(1.0, abs(b))
    }

    func testDefaultWeightsMatchReference() throws {
        let doc = try Self.loadVectors()
        XCTAssertEqual(doc.weights.count, 21)
        for (i, (a, b)) in zip(FSRSParameters.defaultWeights, doc.weights).enumerated() {
            XCTAssertEqual(a, b, accuracy: 1e-12, "w[\(i)]")
        }
    }

    func testMatchesReference() throws {
        let doc = try Self.loadVectors()
        var checked = 0
        for (ci, c) in doc.cases.enumerated() {
            let cfg = doc.configs[c.config]!
            var p = FSRSParameters()
            p.desiredRetention = cfg.desired_retention
            p.learningSteps = cfg.learning_steps
            p.relearningSteps = cfg.relearning_steps
            p.enableFuzzing = false
            let fsrs = FSRS(parameters: p)
            var card = FSRSCard(due: Date(timeIntervalSince1970: c.steps[0].at))
            for (si, s) in c.steps.enumerated() {
                let at = Date(timeIntervalSince1970: s.at)
                let tag = "case \(ci) [\(c.config)] review \(si) rating \(s.rating)"
                XCTAssertTrue(close(fsrs.retrievability(card, at: at), s.r_before), "R before, \(tag)")
                card = fsrs.review(card, rating: Rating(rawValue: s.rating)!, at: at)
                XCTAssertEqual(card.state.rawValue, s.state, "state, \(tag)")
                XCTAssertEqual(card.step, s.step, "step, \(tag)")
                XCTAssertTrue(close(card.stability!, s.stability), "S \(card.stability!) vs \(s.stability), \(tag)")
                XCTAssertTrue(close(card.difficulty!, s.difficulty), "D \(card.difficulty!) vs \(s.difficulty), \(tag)")
                XCTAssertEqual(card.due.timeIntervalSince1970, s.due, accuracy: 0.001, "due, \(tag)")
                if card.state.rawValue != s.state || abs(card.due.timeIntervalSince1970 - s.due) > 0.001 {
                    return  // later steps diverge; first failure is the useful one
                }
                checked += 1
            }
        }
        print("FSRS: \(checked) reviews match py-fsrs \(doc.fsrs_version)")
    }
}

final class FSRSPropertyTests: XCTestCase {
    func testFuzzStaysInRange() {
        let f = FSRS()
        for days in [3, 7, 15, 30, 100, 1000] {
            for r in stride(from: 0.0, to: 1.0, by: 0.05) {
                let v = f.fuzzed(days, random: { r })
                let ivl = Double(days)
                var delta = 1.0
                for (s, e, k) in [(2.5, 7.0, 0.15), (7.0, 20.0, 0.1), (20.0, Double.infinity, 0.05)] {
                    delta += k * max(min(ivl, e) - s, 0)
                }
                XCTAssertGreaterThanOrEqual(v, 2)
                XCTAssertLessThanOrEqual(Double(v), (ivl + delta).rounded() + 1)
                XCTAssertGreaterThanOrEqual(Double(v), (ivl - delta).rounded() - 1)
            }
        }
    }

    func testRetentionTargetMeansIntervalGetsLonger() {
        // Lower target retention -> longer interval, for the same stability.
        var lo = FSRSParameters(); lo.desiredRetention = 0.80
        var hi = FSRSParameters(); hi.desiredRetention = 0.95
        XCTAssertGreaterThan(FSRS(parameters: lo).nextIntervalDays(10), FSRS(parameters: hi).nextIntervalDays(10))
        // At R = 0.9 the interval equals the stability (definition of S in FSRS).
        XCTAssertEqual(FSRS().nextIntervalDays(10), 10)
    }

    func testLapseCountsOnlyFromReview() {
        let f = FSRS(); let t0 = Date(timeIntervalSince1970: 1_767_258_000)
        var c = f.review(FSRSCard(due: t0), rating: .easy, at: t0)
        XCTAssertEqual(c.state, .review)
        c = f.review(c, rating: .again, at: c.due)
        XCTAssertEqual(c.state, .relearning)
        XCTAssertEqual(c.lapses, 1)
        XCTAssertEqual(c.reps, 2)
    }
}
