import XCTest
@testable import MacUtils
@testable import MUCore

final class OnboardingTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "mac-utils.onboarding-tests"
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    func testOnlyExplicitFalseNeedsOnboarding() {
        XCTAssertTrue(FirstRun.needsOnboarding(done: false))
        XCTAssertFalse(FirstRun.needsOnboarding(done: true))
        XCTAssertFalse(FirstRun.needsOnboarding(done: nil), "обновившийся пользователь вводных шагов не видит")
    }

    func testCleanInstallMarksOnboardingPending() {
        let defaults = defaults()
        FirstRun.beginOnboardingIfFirstLaunch(defaults: defaults, firstLaunch: true)
        XCTAssertEqual(defaults.object(forKey: Pref.onboardingDone) as? Bool, false)
    }

    func testExistingUserIsNotOnboarded() {
        let defaults = defaults()
        FirstRun.beginOnboardingIfFirstLaunch(defaults: defaults, firstLaunch: false)
        XCTAssertNil(defaults.object(forKey: Pref.onboardingDone))
    }

    func testFinishedOnboardingIsNotReset() {
        let defaults = defaults()
        defaults.set(true, forKey: Pref.onboardingDone)
        FirstRun.beginOnboardingIfFirstLaunch(defaults: defaults, firstLaunch: true)
        XCTAssertEqual(defaults.object(forKey: Pref.onboardingDone) as? Bool, true)
    }

    func testOnboardingHasThreeSteps() {
        XCTAssertEqual(OnboardingContent.Step.allCases.count, 3)
    }
}
