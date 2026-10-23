import XCTest
@testable import HamsaKit

final class QuestionRulesTests: XCTestCase {
    func testQuestions() {
        let qs = [
            "what GPU does Taweed run on", "Can you share the pricing?", "walk me through the NPHIES flow",
            "وش الـGPU اللي تستخدمونه", "طيب كم سعر المطالبة", "ليش اخترتوا Postgres", "عندكم استضافة داخل المملكة؟",
            "وكيف تتعاملون مع البيانات", "متى تطلقون النسخة", "بكم الباقة الشهرية", "تقدرون تربطون مع نظامنا",
        ]
        for q in qs { XCTAssertGreaterThan(QuestionRules.score(q), 0, q) }
    }

    func testStatements() {
        let ss = [
            "we run on an L4 in Riyadh", "thanks everyone for joining", "الاستضافة عندنا في الرياض",
            "تمام نكمل الاسبوع الجاي", "the demo went well",
        ]
        for s in ss { XCTAssertEqual(QuestionRules.score(s), 0, s) }
    }

    func testNormalizesArabicVariants() {
        XCTAssertEqual(QuestionRules.normalizeArabic("مَتَى"), "متي")
        XCTAssertEqual(QuestionRules.normalizeArabic("أين"), "اين")
    }
}
