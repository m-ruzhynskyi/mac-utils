# Mac Utils Share для Windows

Трансляция экрана по коду и просмотр трансляций Mac Utils на Windows.

- Скачать: [MacUtilsShare-Setup.exe](https://github.com/m-ruzhynskyi/mac-utils/releases/download/windows-latest/MacUtilsShare-Setup.exe)
- «Транслировать свой экран» — выберите экран или окно (со звуком системы или без), получите код из 6 цифр.
- «Смотреть» — введите код трансляции с Mac Utils или другого компьютера.
- Обновляется само (проверка при запуске и каждые 6 часов).

Сборка: ветка `windows`, GitHub Actions собирает на Windows и обновляет релиз `windows-latest`
(помечен как pre-release, чтобы не мешать обновлениям Mac Utils).

Первый запуск: Windows может показать «Система Windows защитила ваш компьютер» — приложение
не подписано сертификатом Microsoft. Нажмите «Подробнее» → «Выполнить в любом случае».

Локально: `npm install && npm start`, тесты — `npm test`.

Метки зрителей ложатся не туда — журнал размещения (только числа: мониторы, масштаб, транслируемая область, окно меток):
`%APPDATA%\Mac Utils Share\logs\overlay.log`.
