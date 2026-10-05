import XCTest
@testable import MeetingPilot

final class ProfileTests: XCTestCase {
    func testStudentAndWorkerChoicesMapToTheSavedProfile() {
        XCTAssertEqual(UserProfile(student: true, worker: true), .both)
        XCTAssertEqual(UserProfile(student: true, worker: false), .student)
        XCTAssertEqual(UserProfile(student: false, worker: true), .worker)
        XCTAssertTrue(UserProfile.both.isStudent && UserProfile.both.isWorker)
        XCTAssertFalse(UserProfile.student.isWorker)
        XCTAssertFalse(UserProfile.worker.isStudent)
    }

    /// Everyone is asked until USER_PROFILE holds an answer, including installs that
    /// predate profiles and had none.
    func testOnlyASavedAnswerSkipsTheProfileQuestion() {
        XCTAssertFalse(UserProfile.isChosen(nil))
        XCTAssertFalse(UserProfile.isChosen(""))
        XCTAssertFalse(UserProfile.isChosen("ask"))
        XCTAssertTrue(UserProfile.isChosen("worker"))
        XCTAssertTrue(UserProfile.isChosen("student"))
        XCTAssertTrue(UserProfile.isChosen("both"))
    }

    /// The pipeline reads these names (config.py); older meeting sections may still be
    /// saved under their Notion-only names.
    func testPageSectionsKeepThePipelineEnvironmentNames() {
        XCTAssertEqual(PageSection.actionItems.envKey, "INCLUDE_ACTION_ITEMS")
        XCTAssertEqual(PageSection.actionItems.legacyEnvKey, "NOTION_INCLUDE_ACTION_ITEMS")
        XCTAssertEqual(PageSection.reviewQuestions.envKey, "INCLUDE_REVIEW_QUESTIONS")
        XCTAssertNil(PageSection.reviewQuestions.legacyEnvKey)
        XCTAssertEqual(
            Set(PageSection.shared + PageSection.meeting + PageSection.lecture),
            Set(PageSection.allCases),
            "every section belongs to exactly one group"
        )
    }
}
