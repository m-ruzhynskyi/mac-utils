import AppKit
import XCTest
@testable import MUCore

/// CRASH-EXCL: запуск Mac Utils, когда на переднем плане программа из списка исключений (AnyDesk, Parallels).
/// В 1.11.0 `AppExclusions.init` синхронно слал `didChangeNotification`, пока `shared` ещё создаётся; подписчик
/// (`AppSwitcher.exclusionChanged`) обращался к `shared` → повторный вход в `dispatch_once`, EXC_BREAKPOINT.
@MainActor
final class ExclusionsLaunchCrashTests: XCTestCase {
    private func posts(_ body: () -> Void) -> Int {
        var count = 0
        let token = NotificationCenter.default.addObserver(forName: AppExclusions.didChangeNotification, object: nil, queue: nil) { _ in
            count += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        body()
        return count
    }

    func testCreatingWithExcludedFrontAppDoesNotNotify() {
        var store: AppExclusions?
        let count = posts {
            store = AppExclusions(list: AppExclusions.defaultList, frontBundleID: "com.philandro.anydesk", observeActivation: false)
        }
        XCTAssertEqual(count, 0, "начальное состояние — без уведомления (подписчик тронул бы ещё не созданный `shared`)")
        XCTAssertEqual(store?.isFrontExcluded, true, "подписчики прочитают его сами при своей настройке")
        let parallels = AppExclusions(list: AppExclusions.defaultList, frontBundleID: "com.parallels.vm.windows11", observeActivation: false)
        XCTAssertTrue(parallels.isFrontExcluded)
        XCTAssertFalse(AppExclusions(list: AppExclusions.defaultList, frontBundleID: "com.apple.finder", observeActivation: false).isFrontExcluded)
    }

    func testLaterChangesStillNotify() {
        let store = AppExclusions(list: AppExclusions.defaultList, frontBundleID: "com.apple.finder", observeActivation: false)
        XCTAssertEqual(posts { store.frontChanged(to: "com.philandro.anydesk") }, 1, "стал исключённым — уведомление")
        XCTAssertTrue(store.isFrontExcluded)
        XCTAssertEqual(posts { store.frontChanged(to: "com.anydesk.anydesk") }, 0, "не изменилось — без уведомления")
        XCTAssertEqual(posts { store.frontChanged(to: "com.apple.finder") }, 1)
        XCTAssertFalse(store.isFrontExcluded)
    }
}
