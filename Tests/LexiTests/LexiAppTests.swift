import XCTest
import SwiftData
import FSRS
@testable import Lexi

@MainActor
final class LexiconTests: XCTestCase {
    func testBundledDatabaseOpens() {
        XCTAssertTrue(Lexicon.shared.isAvailable)
        for lang in Lang.allCases { XCTAssertEqual(Lexicon.shared.wordCount(lang: lang), 10_000, "\(lang)") }
    }

    /// Non-functional requirement: daily deck query < 50 ms (measured here on the CI simulator).
    func testNewWordQueryUnder50ms() {
        _ = Lexicon.shared.newWords(lang: .en, minLevel: 1, categories: [], limit: 5) { _ in false }   // warm up
        let t0 = Date()
        let words = Lexicon.shared.newWords(lang: .en, minLevel: 3, categories: ["food"], limit: 50) { _ in false }
        let ms = Date().timeIntervalSince(t0) * 1000
        print("LEXI_METRIC newWords_ms=\(ms)")
        XCTAssertEqual(words.count, 50)
        XCTAssertLessThan(ms, 50)
        XCTAssertEqual(words.map(\.rank), words.map(\.rank).sorted())
        XCTAssertTrue(words.allSatisfy { $0.level >= 3 })
    }

    func testChineseCardHasPinyinAndBothTranslations() {
        guard let w = Lexicon.shared.search("清楚", langs: [.zh]).first else { return XCTFail("清楚 missing") }
        let f = CardFactory(lexicon: .shared)
        let en = f.card(for: w, mode: .learn, explanation: .en)
        let es = f.card(for: w, mode: .learn, explanation: .es)
        XCTAssertEqual(en.pronunciation, "qīng chu")
        XCTAssertFalse(en.translations.isEmpty)
        XCTAssertFalse(es.translations.isEmpty)
    }

    func testSearchPinyinWithoutTones() {
        XCTAssertTrue(Lexicon.shared.search("qingchu", langs: [.zh]).contains { $0.lemma == "清楚" })
    }
}

@MainActor
final class StudyServiceTests: XCTestCase {
    var container: ModelContainer!
    var study: StudyService!
    var deck: Deck!
    var clock = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        container = try LexiStore.makeContainer(inMemory: true)
        study = StudyService(context: container.mainContext)
        study.now = { [unowned self] in self.clock }
        deck = Deck(mode: .dictionary, study: .en, explanation: .en, minLevel: 1, dailyNewWords: 5)
        container.mainContext.insert(deck)
    }

    func testDailyNewWordsRespectGoalAndAlreadyKnow() {
        let first = study.nextNewKeys(deck: deck, count: 5)
        XCTAssertEqual(first.count, 5)
        study.setAlreadyKnow(first[0], true)
        let again = study.nextNewKeys(deck: deck, count: 5)
        XCTAssertFalse(again.contains(first[0]))
        for k in again { study.introduce(deck: deck, key: k) }
        XCTAssertEqual(study.newWordsLeftToday(deck: deck), 0)
        study.addExtraNewToday(deck: deck, 5)
        XCTAssertEqual(study.newWordsLeftToday(deck: deck), 5)
    }

    func testGradeSchedulesAndLogs() {
        let k = study.nextNewKeys(deck: deck, count: 1)[0]
        study.introduce(deck: deck, key: k)
        XCTAssertEqual(study.dueKeys(deck: deck), [k])
        let c = study.grade(deck: deck, key: k, rating: .easy, responseMs: 1500, source: .wordToMeaning)
        XCTAssertEqual(c.state, .review)
        XCTAssertGreaterThan(c.due, clock)
        XCTAssertEqual(study.dueKeys(deck: deck), [])
        XCTAssertEqual(study.logs(since: .distantPast).count, 1)
        XCTAssertEqual(study.learnedCount(deck: deck), 1)
    }

    func testMistakesAndStreak() {
        let k = study.nextNewKeys(deck: deck, count: 1)[0]
        study.grade(deck: deck, key: k, rating: .again, responseMs: 900, source: .spelling)
        XCTAssertEqual(study.mistakeKeys(deck: deck), [k])
        XCTAssertEqual(study.streak(), 1)
    }

    func testBackupRoundTrip() throws {
        let k = study.nextNewKeys(deck: deck, count: 1)[0]
        study.grade(deck: deck, key: k, rating: .good, responseMs: 3000, source: .listening)
        study.toggleFavorite(k)
        let json = try Transfer.backupJSON(context: container.mainContext)
        let other = try LexiStore.makeContainer(inMemory: true)
        let msg = try Transfer.restore(json: Data(json.utf8), context: other.mainContext)
        XCTAssertTrue(msg.contains("1"))
        let s2 = StudyService(context: other.mainContext)
        XCTAssertEqual(s2.decks().count, 1)
        XCTAssertEqual(s2.favoriteKeys(), [k])
        XCTAssertEqual(s2.logs(since: .distantPast).count, 1)
    }

    func testCSVImport() {
        let msg = Transfer.importCSV(text: "word,definition,example\nserendipity,a happy accident,\nserendipity,dup,\n,missing,\n",
                                     deck: deck, context: container.mainContext)
        XCTAssertEqual(study.customWords(deck: deck).count, 1)
        XCTAssertTrue(msg.contains("1"))
        XCTAssertEqual(study.nextNewKeys(deck: deck, count: 1).first?.hasPrefix("custom:"), true)
    }
}
