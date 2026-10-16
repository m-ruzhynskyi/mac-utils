import Foundation

/// Что показать при запуске (чистая логика): на чистой установке — одно окно вместо трёх.
enum FirstRun {
    struct Plan: Equatable {
        var showSettings: Bool
        var offerMove: Bool
    }

    /// Окно настроек: на первом запуске и пока нет «Универсального доступа». Вопрос «Перенести в Программы?» не показываем
    /// поверх окна настроек: он задаётся в запуске, где настройки не открываются (иначе на чистой установке сразу два окна).
    static func plan(firstLaunch: Bool, accessibility: Bool, wantsMoveOffer: Bool) -> Plan {
        let showSettings = firstLaunch || !accessibility
        return Plan(showSettings: showSettings, offerMove: wantsMoveOffer && !showSettings)
    }

    /// Чистая установка не получает «Что нового» (это не обновление): текущая линейка записывается как уже виденная.
    /// Тот, кто обновился со старой версии (приветствие уже показывали), «Что нового» увидит.
    static func seedChangelog(defaults: UserDefaults, current: String, welcomeShown: Bool) {
        guard !welcomeShown, defaults.string(forKey: Pref.lastSeenChangelog) == nil else { return }
        defaults.set(current, forKey: Pref.lastSeenChangelog)
    }

    /// Вводные шаги нужны только на чистой установке: ключ явно `false`. У обновившегося пользователя его нет.
    static func needsOnboarding(done: Bool?) -> Bool { done == false }

    /// На чистой установке отмечает, что вводные шаги ещё не пройдены (один раз; пройденные не сбрасываются).
    static func beginOnboardingIfFirstLaunch(defaults: UserDefaults, firstLaunch: Bool) {
        guard firstLaunch, defaults.object(forKey: Pref.onboardingDone) == nil else { return }
        defaults.set(false, forKey: Pref.onboardingDone)
    }
}
