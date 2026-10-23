# Ввод пароля в окно «Аутентификация» TeamViewer через UI Automation. Вход: stdin — строка 1: параметры JSON
# {"timeoutMs":N,"id":"…","noPassword":true?}; строка 2 — пароль, но только ПОСЛЕ события "passwordField": модуль читает пароль из
# файла, когда поле найдено и проверено, и лишь тогда дописывает его в stdin (пустая строка — пароля в файле больше нет). При
# noPassword вторую строку скрипт не читает. В аргументах командной строки пароля нет; ни в вывод, ни в файлы он не пишется.
# Выход: строки JSON — события {"state":"ready"|"waiting"|"idSubmitted"|"intermediate"|"passwordField"|"confirming"} и один итог:
# "connected" | "session" | "submitted" | "sessionClosed" | "passwordNeeded" | "noPrompt" | "noWindow" | "idMismatch" | "elevated"
# | "focusLost" | "fieldNotFound" | "wrongPassword".
#
# Подтверждение — только окно сеанса: НОВОЕ окно TeamViewer, в заголовке которого есть цифры ID (пробелы не важны), без поля пароля
# и без индикатора хода, и оно держится SettleMs. Без пароля это "session"; после ввода пароля — "connected". После пароля окна
# сеанса нет к сроку — "submitted" (пароль введён, сеанс не подтверждён); окно сеанса закрылось или TeamViewer сообщил о закрытии —
# "sessionClosed". Без пароля к сроку: окно TeamViewer было (клиент открыт), но ни пароля, ни сеанса — "noPrompt"; ни одного окна
# TeamViewer не было вовсе (клиент не запустился; служба TeamViewer_Service и TeamViewer_Desktop окнами не считаются) — "noWindow".
# Запасной путь: TeamViewer открылся на главном экране без ID (запуск с -i в новых версиях не подставляет ID) — находим поле ID по
# подписи/подсказке (новый интерфейс «ID, IP address, or hostname» / «Enter end user's ID, IP, or hostname», старый «Partner ID»),
# вставляем ID через ValuePattern и нажимаем «Connect» через InvokePattern — только кнопку из ближайшего общего контейнера поля
# (не плитку устройства из списка); такой кнопки нет — Enter в поле ID, пока оно в фокусе. В поле уже стоит этот ID — не вводим и
# не нажимаем второй раз. Окно пароля показывает другой ID — пароль не вводим ("idMismatch").
# Кнопки отмены/отказа/закрытия не нажимаются никогда. Пока открыто окно хода подключения — ожидание продлевается (до двух сроков).
# Файл — UTF-8 с BOM: Windows PowerShell 5.1 читает .ps1 без BOM в кодировке ANSI, и кириллица в шаблонах подписей исказилась бы.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class MuNative {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr t, int cls, out int info, int len, out int ret);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  // Процесс запущен от администратора. Не удалось даже открыть процесс с минимальными правами (PROCESS_QUERY_LIMITED_INFORMATION) или
  // его токен — он «выше нас»: так же отвечает Windows для поднятого процесса.
  public static bool Elevated(int pid) {
    IntPtr process = OpenProcess(0x1000, false, pid);
    if (process == IntPtr.Zero) return true;
    try {
      IntPtr token; if (!OpenProcessToken(process, 8, out token)) return true;
      try { int v; int ret; return GetTokenInformation(token, 20, out v, 4, out ret) && v != 0; } finally { CloseHandle(token); }
    } finally { CloseHandle(process); }
  }
}
'@
function Emit($state) { [Console]::Out.WriteLine((@{ state = $state } | ConvertTo-Json -Compress)); [Console]::Out.Flush() }

# Вход — UTF-8 независимо от кодовой страницы консоли (иначе пароль не на латинице искажается): читаем байты stdin сами.
$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
$options = $reader.ReadLine() | ConvertFrom-Json
# Пароля здесь ещё нет: его вторая строка придёт только после "passwordField".
$password = $null
$timeoutMs = [double]$options.timeoutMs
$started = [DateTime]::UtcNow
$deadline = $started.AddMilliseconds($timeoutMs)
# Ожидание окна пароля продлевается не дольше двух сроков; проверка сеанса после ввода пароля — ещё не дольше срока сверх того.
$limit = $started.AddMilliseconds($timeoutMs * 2)
$hardLimit = $started.AddMilliseconds($timeoutMs * 3)
$partnerId = [string]$options.id
$digits = $partnerId -replace '\D', ''
$noPassword = [bool]$options.noPassword
$SettleMs = 2000
$CloseMs = 1500
# Запасной ввод ID — не раньше, чем TeamViewer успел бы сам открыть подключение по -i (без окна хода оно бывает не сразу).
$graceUntil = $started.AddMilliseconds([Math]::Min(8000, $timeoutMs / 2))
$root = [System.Windows.Automation.AutomationElement]::RootElement
$isEdit = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
$isButton = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$isProgress = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ProgressBar)
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
# Поле ID партнёра: старый интерфейс «Partner ID» / «ID партнёра», новый «ID, IP address, or hostname» с подсказкой
# «Enter end user's ID, IP, or hostname».
$idFieldPattern = '(?i)(partner[\s-]*id|id[\s-]*(des\s+)?partner|\bid\s+партн|партн\S*\s+id|end user.?s id|\bID,\s*IP\b|remote[\s-]*id)'
# Кнопка продолжения рядом с полем ID — только «Connect» и переводы; «Search and Connect» и прочее не подходит.
$connectPattern = '(?i)^(connect|connect to partner|подключиться|подключиться к партнеру|подключиться к партнёру|подключить|verbinden|mit partner verbinden|підключитися|połącz)$'
# Отмена, отказ, закрытие — не нажимаем никогда, даже если подпись совпала бы.
$denyPattern = '(?i)(cancel|deny|reject|close|abort|отмен|отклон|закры|abbrechen|ablehnen|schlie|скасув|відхил|закри|anuluj|odrzu|zamknij)'
$connectingPattern = '(?i)(connecting|подключени|verbinde|з.єднання|łączenie)'
$failedPattern = '(?i)(error|fail|ошибк|не удалось|fehler|помилк|błąd)'
# TeamViewer сообщил, что сеанс или соединение закрыто.
$closedPattern = '(?i)(session (was |has been |has |been )?(ended|closed|terminated)|connection (was |has been |has |been )?(closed|lost|terminated|ended)|сеанс (был )?(завершён|завершен|закрыт|окончен|прерван)|соединение (было )?(закрыто|разорвано|прервано|потеряно)|сеанс (було )?(завершено|закрито)|з.єднання (було )?(закрито|розірвано|втрачено)|sitzung (wurde )?beendet|verbindung (wurde )?(getrennt|beendet))'
# Списки устройств и недавних: «Connect» внутри них — кнопка плитки другого компьютера, контейнер поля ID на них не расширяем.
$listTypes = @([System.Windows.Automation.ControlType]::List, [System.Windows.Automation.ControlType]::ListItem, [System.Windows.Automation.ControlType]::DataGrid, [System.Windows.Automation.ControlType]::DataItem, [System.Windows.Automation.ControlType]::Tree, [System.Windows.Automation.ControlType]::TreeItem, [System.Windows.Automation.ControlType]::Table)

# Все окна TeamViewer, открытые до запуска: окно прежнего сеанса не может подтвердить новый.
$knownWindows = New-Object System.Collections.Generic.HashSet[int]

# Процессы клиента TeamViewer. Служба (TeamViewer_Service) работает всегда, TeamViewer_Desktop — в сессии пользователя: по ним нельзя
# судить, что клиент открылся, и окон подключения у них нет.
$serviceNames = @('TeamViewer_Service', 'TeamViewer_Desktop')
function Get-TeamViewerIds { @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'TeamViewer*' -and $serviceNames -notcontains $_.ProcessName } | ForEach-Object { $_.Id }) }

# Окна пароля, уже открытые до запуска подключения (прежнее подключение, чужой диалог): их игнорируем, пароль уйдёт только в новое.
$baseline = New-Object System.Collections.Generic.HashSet[int]

# Окно пароля: окно процесса TeamViewer с полем ввода, помеченным как пароль.
function Find-PasswordField($ids, $skipKnown = $true) {
  foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    if ($ids -notcontains $window.Current.ProcessId) { continue }
    if ($skipKnown -and $baseline.Contains([int]$window.Current.NativeWindowHandle)) { continue }
    foreach ($edit in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isEdit)) {
      if ($edit.Current.IsPassword) { return @{ Window = $window; Edit = $edit } }
    }
  }
  return $null
}

# Продление срока: не раньше текущего и не позже двух исходных сроков.
function Get-Extended($until) {
  if ($until -le $deadline) { return $deadline }
  if ($until -gt $limit) { return $limit }
  return $until
}

function Get-TeamViewerWindows($ids) {
  @($root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $ids -contains $_.Current.ProcessId })
}

# Подписи элемента: имя, подсказка (часто здесь placeholder), AutomationId и подпись-метка.
function Get-Labels($element) {
  $labels = @($element.Current.Name, $element.Current.HelpText, $element.Current.AutomationId)
  try { $by = $element.Current.LabeledBy; if ($by) { $labels += $by.Current.Name } } catch {}
  # Старый интерфейс: поле ID — редактируемый список, подпись у самого списка.
  try {
    $parent = $walker.GetParent($element)
    if ($parent -and $parent.Current.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox) { $labels += @($parent.Current.Name, $parent.Current.HelpText, $parent.Current.AutomationId) }
  } catch {}
  ($labels | Where-Object { $_ }) -join ' | '
}

# Новое окно TeamViewer с индикатором хода или заголовком «Подключение…» — промежуточное окно: ждём дальше.
function Test-Intermediate($ids) {
  foreach ($window in Get-TeamViewerWindows $ids) {
    if ($knownWindows.Contains([int]$window.Current.NativeWindowHandle)) { continue }
    if ($window.Current.Name -match $connectingPattern) { return $true }
    if ($window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $isProgress)) { return $true }
  }
  return $false
}

# Окно сеанса: новое окно TeamViewer, в заголовке — цифры ID (пробелы и разделители не важны), нет поля пароля и индикатора хода.
function Find-SessionWindow($ids) {
  if ($digits.Length -lt 5) { return $null }
  foreach ($window in Get-TeamViewerWindows $ids) {
    if ($knownWindows.Contains([int]$window.Current.NativeWindowHandle)) { continue }
    if (($window.Current.Name -replace '\D', '') -notlike "*$digits*") { continue }
    # «Подключение к …» и «Ошибка подключения к …» — не сеанс, даже если в заголовке ID.
    if ($window.Current.Name -match $connectingPattern -or $window.Current.Name -match $failedPattern) { continue }
    if ($window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $isProgress)) { continue }
    $hasPassword = $false
    foreach ($edit in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isEdit)) { if ($edit.Current.IsPassword) { $hasPassword = $true; break } }
    if (-not $hasPassword) { return $window }
  }
  return $null
}

# Есть ли внутри элемента список устройств/недавних.
function Test-HasList($scope) {
  foreach ($type in $listTypes) {
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $type)
    if ($scope.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)) { return $true }
  }
  return $false
}

# Кнопка «Connect» формы ID: только в ближайшем общем контейнере поля — первый предок (не выше 3 уровней и не само окно), в котором
# есть кнопки «Connect». Всё окно не просматриваем: там плитки устройств со своими «Connect». Контейнер со списком устройств или с
# несколькими «Connect» — не форма поля: кнопки нет (тогда Enter в поле). Кнопки отмены/закрытия исключены.
function Find-ConnectButton($window, $edit) {
  $node = $edit
  for ($i = 0; $i -lt 3; $i++) {
    $node = $walker.GetParent($node)
    if (-not $node -or [System.Windows.Automation.Automation]::Compare($node, $window) -or $node.Current.ProcessId -ne $window.Current.ProcessId) { return $null }
    $hits = @()
    foreach ($button in $node.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isButton)) {
      $name = [string]$button.Current.Name
      if ($name -match $denyPattern) { continue }
      if ($name -match $connectPattern) { $hits += $button }
    }
    if ($hits.Count -eq 0) { continue }
    if ($hits.Count -gt 1 -or (Test-HasList $node)) { return $null }
    if ($hits[0].Current.IsEnabled) { return $hits[0] }
    return $null
  }
  return $null
}

# Владелец окна переднего плана.
function Get-ForegroundPid { $owner = 0; [void][MuNative]::GetWindowThreadProcessId([MuNative]::GetForegroundWindow(), [ref]$owner); [int]$owner }

# Запасной путь: главный экран TeamViewer без ID. Поле ищем по подписи/подсказке, ID ставим через ValuePattern, «Connect» — Invoke;
# кнопки формы нет — Enter в поле ID, только пока поле в фокусе, а окно TeamViewer впереди.
# Итог: "submitted" — ID введён и подтверждён; "present" — в поле уже этот ID (запуск с -i сработал): второй раз не вводим и не
# нажимаем; "" — поля нет или подтвердить нечем.
function Submit-PartnerId($ids) {
  if (-not $digits) { return '' }
  foreach ($window in Get-TeamViewerWindows $ids) {
    foreach ($edit in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isEdit)) {
      try {
        if ($edit.Current.IsPassword -or -not $edit.Current.IsEnabled) { continue }
        if ((Get-Labels $edit) -notmatch $idFieldPattern) { continue }
        $value = $null
        if (-not $edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$value)) { continue }
        if ($value.Current.IsReadOnly) { continue }
        if (([string]$value.Current.Value -replace '\D', '') -eq $digits) { return 'present' }
        $button = Find-ConnectButton $window $edit
        $invoke = $null
        if ($button -and -not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) { $button = $null }
        $value.SetValue($partnerId)
        if ($button) { $invoke.Invoke(); return 'submitted' }
        $tvPid = [int]$window.Current.ProcessId
        if ((Get-ForegroundPid) -ne $tvPid) { [void][MuNative]::SetForegroundWindow([IntPtr]$window.Current.NativeWindowHandle); Start-Sleep -Milliseconds 200 }
        $edit.SetFocus()
        Start-Sleep -Milliseconds 100
        if ((Get-ForegroundPid) -eq $tvPid -and $edit.Current.HasKeyboardFocus) { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); return 'submitted' }
        return ''
      } catch { continue }
    }
  }
  return ''
}

# Номера, которые показывает окно (заголовок и тексты): цифры через пробел, не короче 7 — так TeamViewer пишет ID партнёра
# (даты и версии с точками сюда не попадают).
function Get-ShownIds($window) {
  $texts = @([string]$window.Current.Name)
  $isText = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
  foreach ($text in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isText)) { $texts += [string]$text.Current.Name }
  $shown = @()
  foreach ($t in $texts) {
    foreach ($m in [regex]::Matches($t, '\d[\d \u00A0]{5,}\d')) { $n = $m.Value -replace '\D', ''; if ($n.Length -ge 7) { $shown += $n } }
  }
  return $shown
}

# Новое окно TeamViewer сообщает о закрытом сеансе.
function Test-SessionClosed($ids) {
  foreach ($window in Get-TeamViewerWindows $ids) {
    if ($knownWindows.Contains([int]$window.Current.NativeWindowHandle)) { continue }
    if ($window.Current.Name -match $closedPattern) { return $true }
    $isText = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    foreach ($text in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isText)) { if ([string]$text.Current.Name -match $closedPattern) { return $true } }
  }
  return $false
}

try {
  # Запоминаем уже открытые окна (пароля — отдельно) и сообщаем «готов»: TeamViewer запускается только после этого.
  $startIds = Get-TeamViewerIds
  foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    if ($startIds -contains $window.Current.ProcessId) {
      [void]$knownWindows.Add([int]$window.Current.NativeWindowHandle)
      foreach ($edit in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isEdit)) { if ($edit.Current.IsPassword) { [void]$baseline.Add([int]$window.Current.NativeWindowHandle) } }
    }
  }
  Emit 'ready'
  $found = $null
  $tick = 0
  $submitted = $false
  $wasIntermediate = $false
  $sessionHandle = 0
  $sessionSince = $null
  # Клиент TeamViewer открыт: есть хотя бы одно его окно верхнего уровня (процессы службы не в счёт).
  $sawWindow = $false
  while ([DateTime]::UtcNow -lt $deadline) {
    $now = [DateTime]::UtcNow
    $ids = Get-TeamViewerIds
    if ($ids.Count) {
      if ((Get-TeamViewerWindows $ids).Count) { $sawWindow = $true }
      $found = Find-PasswordField $ids; if ($found) { break }
      # Окно сеанса должно устояться: мелькнувшее окно не подтверждение.
      $session = Find-SessionWindow $ids
      if ($session) {
        $handle = [int]$session.Current.NativeWindowHandle
        if ($handle -ne $sessionHandle) { $sessionHandle = $handle; $sessionSince = $now }
        elseif (($now - $sessionSince).TotalMilliseconds -ge $SettleMs) { Emit 'session'; return }
      } else { $sessionHandle = 0; $sessionSince = $null }
      $intermediate = Test-Intermediate $ids
      if ($intermediate) {
        if (-not $wasIntermediate) { Emit 'intermediate' }
        $deadline = Get-Extended $now.AddMilliseconds(3000)
      }
      $wasIntermediate = $intermediate
      # Ни окна пароля, ни хода подключения, ни окна сеанса после запуска — TeamViewer открылся без ID: вводим сами, один раз.
      if (-not $submitted -and -not $intermediate -and -not $session -and $now -ge $graceUntil -and ($tick % 2) -eq 0) {
        $submit = Submit-PartnerId $ids
        if ($submit -eq 'present') { $submitted = $true }
        elseif ($submit -eq 'submitted') {
          $submitted = $true
          Emit 'idSubmitted'
          $deadline = Get-Extended ([DateTime]::UtcNow.AddMilliseconds($timeoutMs))
        }
      }
    }
    if (($tick++ % 4) -eq 0) { Emit 'waiting' }
    Start-Sleep -Milliseconds 250
  }
  # Ни окна пароля, ни сеанса: клиент открыт (его окно видели) — "noPrompt"; окон TeamViewer не было вовсе — "noWindow".
  if (-not $found) { if ($sawWindow) { Emit 'noPrompt' } else { Emit 'noWindow' }; return }
  # Пароля в файле нет: окно пароля найдено, вводит пользователь.
  if ($noPassword) { Emit 'passwordNeeded'; return }

  $pid2 = $found.Window.Current.ProcessId
  $process = Get-Process -Id $pid2
  if ($process.ProcessName -notlike 'TeamViewer*' -or $serviceNames -contains $process.ProcessName) { Emit 'focusLost'; return }
  if ([MuNative]::Elevated($pid2) -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Emit 'elevated'; return }

  # Окно пароля показывает ID партнёра — он должен совпасть с записью: пароль записи X не уходит компьютеру Y.
  if ($digits.Length -ge 5) {
    $shown = @(Get-ShownIds $found.Window)
    if ($shown.Count -and $shown -notcontains $digits) { Emit 'idMismatch'; return }
  }

  # Фокус: окно пароля должно быть на переднем плане и принадлежать TeamViewer; иначе одна попытка вернуть, потом отказ.
  $handle = [IntPtr]$found.Window.Current.NativeWindowHandle
  if ((Get-ForegroundPid) -ne $pid2) { [void][MuNative]::SetForegroundWindow($handle); Start-Sleep -Milliseconds 200 }
  if ((Get-ForegroundPid) -ne $pid2) { Emit 'focusLost'; return }

  $pattern = $null
  if (-not $found.Edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) { Emit 'fieldNotFound'; return }

  # Поле найдено и проверено — только теперь просим пароль: модуль читает его из файла и дописывает второй строкой stdin.
  Emit 'passwordField'
  $password = $reader.ReadLine()
  if (-not $password) { $password = $null; Emit 'passwordNeeded'; return }
  # Пока читали файл, фокус мог уйти.
  if ((Get-ForegroundPid) -ne $pid2) { Emit 'focusLost'; return }
  $pattern.SetValue($password)
  $password = $null

  # Подтвердить: кнопка по умолчанию окна (OK / Войти / Log On), иначе Enter — только пока окно пароля на переднем плане.
  $button = $null
  foreach ($candidate in $found.Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isButton)) {
    if ($candidate.Current.Name -match '^(OK|ОК|Log ?On|Войти|Увійти|Anmelden)$') { $button = $candidate; break }
  }
  if ($button) { $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
  elseif ((Get-ForegroundPid) -eq $pid2) { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') }
  else { Emit 'focusLost'; return }

  # Окно пароля осталось (или появилось снова) — пароль не принят.
  Start-Sleep -Milliseconds 2500
  if (Find-PasswordField (Get-TeamViewerIds)) { Emit 'wrongPassword'; return }

  # Пароль ушёл — это ещё не сеанс. «Подключено» — только когда устоится окно сеанса с ID партнёра; TeamViewer сообщил о закрытии
  # или окно сеанса закрылось — "sessionClosed"; к сроку ничего — "submitted".
  Emit 'confirming'
  $confirmUntil = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  if ($confirmUntil -gt $hardLimit) { $confirmUntil = $hardLimit }
  $sessionHandle = 0; $sessionSince = $null; $sawSession = $false; $goneSince = $null
  while ([DateTime]::UtcNow -lt $confirmUntil) {
    $now = [DateTime]::UtcNow
    $ids = Get-TeamViewerIds
    if (Test-SessionClosed $ids) { Emit 'sessionClosed'; return }
    if (Find-PasswordField $ids) { Emit 'wrongPassword'; return }
    $session = Find-SessionWindow $ids
    if ($session) {
      $sawSession = $true; $goneSince = $null
      $h = [int]$session.Current.NativeWindowHandle
      if ($h -ne $sessionHandle) { $sessionHandle = $h; $sessionSince = $now }
      elseif (($now - $sessionSince).TotalMilliseconds -ge $SettleMs) { Emit 'connected'; return }
    } else {
      $sessionHandle = 0; $sessionSince = $null
      # Окно сеанса этого подключения было и закрылось (не мелькнуло: его нет дольше CloseMs).
      if ($sawSession) {
        if (-not $goneSince) { $goneSince = $now }
        elseif (($now - $goneSince).TotalMilliseconds -ge $CloseMs) { Emit 'sessionClosed'; return }
      }
    }
    # Пока TeamViewer показывает ход подключения — ждём дольше, но не позже общего предела.
    if (Test-Intermediate $ids) {
      $later = [DateTime]::UtcNow.AddMilliseconds(3000)
      if ($later -gt $confirmUntil) { $confirmUntil = $later }
      if ($confirmUntil -gt $hardLimit) { $confirmUntil = $hardLimit }
    }
    Start-Sleep -Milliseconds 250
  }
  Emit 'submitted'
} catch {
  Emit 'fieldNotFound'
} finally {
  $password = $null
}
