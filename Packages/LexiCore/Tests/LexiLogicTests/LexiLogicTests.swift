import XCTest
import FSRS
@testable import LexiLogic

final class GradingTests: XCTestCase {
    func testMapping() {
        let t = GradeThresholds(fast: 2.5, slow: 8)
        XCTAssertEqual(Grader.rating(correct: false, seconds: 1, thresholds: t), .again)
        XCTAssertEqual(Grader.rating(correct: true, seconds: 2.5, thresholds: t), .easy)
        XCTAssertEqual(Grader.rating(correct: true, seconds: 5, thresholds: t), .good)
        XCTAssertEqual(Grader.rating(correct: true, seconds: 8, thresholds: t), .good)
        XCTAssertEqual(Grader.rating(correct: true, seconds: 8.01, thresholds: t), .hard)
        XCTAssertEqual(Grader.rating(correct: true, seconds: 1, thresholds: t, usedHint: true), .hard)
        XCTAssertEqual(Grader.rating(correct: false, seconds: 1, thresholds: t, usedHint: true), .again)
    }

    func testSpellingScalesWithLength() {
        let short = GradeThresholds.forGame(.spelling, answerLength: 3)
        let long = GradeThresholds.forGame(.spelling, answerLength: 12)
        XCTAssertEqual(short.fast, 1.5 + 0.35 * 3, accuracy: 1e-9)
        XCTAssertEqual(long.slow, 6 + 12, accuracy: 1e-9)
        XCTAssertLessThan(short.slow, long.slow)
    }
}

final class PinyinTests: XCTestCase {
    func testMarks() {
        XCTAssertEqual(Pinyin.marked(numbered: "qing1 chu5"), "qīng chu")
        XCTAssertEqual(Pinyin.marked(numbered: "lu:4"), "lǜ")
        XCTAssertEqual(Pinyin.marked(numbered: "lv4"), "lǜ")
        XCTAssertEqual(Pinyin.marked(numbered: "gou3"), "gǒu")
        XCTAssertEqual(Pinyin.marked(numbered: "gui4"), "guì")
        XCTAssertEqual(Pinyin.marked(numbered: "liu2"), "liú")
        XCTAssertEqual(Pinyin.marked(numbered: "Zhong1"), "Zhōng")
    }

    func testNumbered() {
        XCTAssertEqual(Pinyin.numbered(marked: "qīng chu"), "qing1 chu5")
        XCTAssertEqual(Pinyin.numbered(marked: "nǚ ér"), "nü3 er2")
    }

    func testAnswerMatching() {
        let a = "qīng chu"
        XCTAssertTrue(Pinyin.matches(typed: "qingchu", answerMarked: a))
        XCTAssertTrue(Pinyin.matches(typed: "qing chu", answerMarked: a))
        XCTAssertTrue(Pinyin.matches(typed: "qing1chu5", answerMarked: a))
        XCTAssertTrue(Pinyin.matches(typed: "qing1chu", answerMarked: a))     // neutral digit optional
        XCTAssertTrue(Pinyin.matches(typed: "qing1 chu0", answerMarked: a))
        XCTAssertTrue(Pinyin.matches(typed: "QĪNG CHU", answerMarked: a))
        XCTAssertTrue(Pinyin.matches(typed: "qīngchu", answerMarked: a))
        XCTAssertFalse(Pinyin.matches(typed: "qing2chu", answerMarked: a))   // wrong tone
        XCTAssertFalse(Pinyin.matches(typed: "qíng chu", answerMarked: a))
        XCTAssertFalse(Pinyin.matches(typed: "qin1chu", answerMarked: a))    // wrong letters
        XCTAssertFalse(Pinyin.matches(typed: "qi1ngchu", answerMarked: a))   // digit not at syllable end
        XCTAssertTrue(Pinyin.matches(typed: "lv4", answerMarked: "lǜ"))
        XCTAssertTrue(Pinyin.matches(typed: "lu4", answerMarked: "lǜ"))
        XCTAssertTrue(Pinyin.matches(typed: "nü3", answerMarked: "nǚ"))
    }

    func testToneOptions() {
        var seed: UInt64 = 42
        let rnd: () -> Double = {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let opts = Pinyin.toneOptions(answerMarked: "qīng chu", count: 4, random: rnd)
        XCTAssertEqual(opts.first, "qīng chu")
        XCTAssertEqual(opts.count, 4)                 // first syllable has 4 tones, neutral stays fixed
        XCTAssertEqual(Set(opts).count, 4)
        XCTAssertTrue(opts.allSatisfy { $0.hasSuffix(" chu") })
        let two = Pinyin.toneOptions(answerMarked: "xué xí", count: 4, random: rnd)
        XCTAssertEqual(Set(two).count, 4)
    }
}

final class CSVTests: XCTestCase {
    func testRoundTrip() {
        let rows = [["word", "definition"], ["lucid", "clear, \"easy\" to understand"], ["a,b", "line1\nline2"]]
        XCTAssertEqual(CSV.parse(CSV.write(rows)), rows)
    }

    func testRecordsAndBOM() {
        let text = "\u{FEFF}Word,Definition,Example\r\nlucid,clear,\r\n\r\nserene,calm,A serene lake.\r\n"
        let r = CSV.records(text)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0]["word"], "lucid")
        XCTAssertNil(r[0]["example"])
        XCTAssertEqual(r[1]["example"], "A serene lake.")
    }
}

final class StatsTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    func day(_ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))!
    }

    func testStreak() {
        XCTAssertEqual(StatsMath.streak(reviewDays: [day(3), day(4), day(5, 23)], today: day(5, 8), calendar: cal), 3)
        XCTAssertEqual(StatsMath.streak(reviewDays: [day(3), day(4)], today: day(5), calendar: cal), 2)   // today not yet
        XCTAssertEqual(StatsMath.streak(reviewDays: [day(2), day(4)], today: day(5), calendar: cal), 1)
        XCTAssertEqual(StatsMath.streak(reviewDays: [day(1)], today: day(5), calendar: cal), 0)
    }

    func testPerDay() {
        let r = StatsMath.perDay([day(4), day(4, 20), day(5)], days: 3, today: day(5), calendar: cal)
        XCTAssertEqual(r.map(\.count), [0, 2, 1])
    }

    func testRetention() {
        let logs: [(priorState: CardState?, rating: Rating)] = [
            (.review, .good), (.review, .again), (.review, .hard), (.review, .easy), (.learning, .again),
        ]
        XCTAssertEqual(StatsMath.retention(logs)!, 0.75, accuracy: 1e-9)
        XCTAssertNil(StatsMath.retention([(.learning, .good)]))
    }

    func testReminderPlan() {
        let now = day(5, 10)
        let ten = ReminderPlan.fireDates(perDay: 10, startMinute: 9 * 60, endMinute: 21 * 60, from: now, calendar: cal)
        XCTAssertLessThanOrEqual(ten.count, 64)
        XCTAssertTrue(ten.allSatisfy { $0 > now })
        // slots 9:00, 10:20 … 21:00 for days 0…6 = 70, minus today's 9:00 (past) = 69 → capped at 64
        XCTAssertEqual(ten.count, 64)
        XCTAssertEqual(ReminderPlan.fireDates(perDay: 0, startMinute: 0, endMinute: 60, from: now, calendar: cal).count, 0)
        let one = ReminderPlan.fireDates(perDay: 1, startMinute: 9 * 60, endMinute: 9 * 60, from: day(5, 8), calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: one[0]), 9)
    }
}

final class TextMatchTests: XCTestCase {
    func testNormalize() {
        XCTAssertTrue(TextMatch.equal("Está", "esta"))
        XCTAssertTrue(TextMatch.accentOnly("esta", "está"))
        XCTAssertFalse(TextMatch.accentOnly("está", "está"))
        XCTAssertTrue(TextMatch.equal(" lucid! ", "lucid"))
    }

    func testBlank() {
        XCTAssertEqual(TextMatch.blank("I run every day.", word: "run", isChinese: false), "I _____ every day.")
        XCTAssertEqual(TextMatch.blank("She runs fast.", word: "run", isChinese: false), "She _____ fast.")
        XCTAssertEqual(TextMatch.blank("Brunch is late.", word: "run", isChinese: false), nil)
        XCTAssertEqual(TextMatch.blank("我听不清楚。", word: "清楚", isChinese: true), "我听不_____。")
    }
}

final class WidgetRotationTests: XCTestCase {
    func testScheduleHourly() {
        let now = Date(timeIntervalSince1970: 3600 * 1000 + 1234)   // 20:34 into an hour slot
        let s = WidgetRotation.schedule(now: now, intervalMinutes: 60)
        XCTAssertEqual(s.count, 25)                                 // 1440/60 + 1
        XCTAssertEqual(s[0].date, now)
        XCTAssertEqual(s[0].slot, 1000)
        XCTAssertEqual(s[1].date, Date(timeIntervalSince1970: 3600 * 1001))
        XCTAssertEqual(s.last!.slot, 1024)
    }

    func testScheduleBounds() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(WidgetRotation.schedule(now: now, intervalMinutes: 5).count, 96)      // clamped to 15 min → 97 → 96
        XCTAssertEqual(WidgetRotation.schedule(now: now, intervalMinutes: 1440).count, 2)
        let s = WidgetRotation.schedule(now: now, intervalMinutes: 15)
        XCTAssertEqual(s[2].date.timeIntervalSince(s[1].date), 900)
    }

    func testIndex() {
        XCTAssertEqual(WidgetRotation.index(slot: 10, offset: 0, count: 3), 1)
        XCTAssertEqual(WidgetRotation.index(slot: 10, offset: 1, count: 3), 2)
        XCTAssertEqual(WidgetRotation.index(slot: -4, offset: 0, count: 3), 2)
        XCTAssertEqual(WidgetRotation.index(slot: Int.max, offset: 5, count: 7),
                       WidgetRotation.index(slot: Int.max, offset: 5, count: 7))
    }

    func testWidgetGradeIsGoodWhenCorrect() {
        XCTAssertEqual(Grader.rating(kind: .widget, correct: true, seconds: 0), .good)
        XCTAssertEqual(Grader.rating(kind: .widget, correct: true, seconds: 999), .good)
    }
}
