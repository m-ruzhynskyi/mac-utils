# Ввод пароля в окно «Аутентификация» TeamViewer через UI Automation. Вход: stdin — строка 1: параметры JSON
# {"timeoutMs":N,"id":"…","noPassword":true?}, строка 2: пароль (пустая при noPassword; в аргументах командной строки пароля нет).
# Выход: строки JSON — события {"state":"ready"|"waiting"|"idSubmitted"|"intermediate"} и один итог: "entered" | "session"
# | "passwordNeeded" | "noPrompt" | "noWindow" | "elevated" | "focusLost" | "fieldNotFound" | "wrongPassword". Пароль не пишется ни в вывод, ни в файлы.
#
# Успех без пароля ("session") — только когда найдено НОВОЕ окно TeamViewer, в заголовке которого есть цифры ID (пробелы не важны),
# без поля пароля и без индикатора хода, и оно держится SettleMs. Таймаут без окна пароля и без окна сеанса — не успех: процесс
# TeamViewer был — "noPrompt", не было — "noWindow".
# Запасной путь: TeamViewer открылся на главном экране без ID (запуск с -i в новых версиях не подставляет ID) — находим поле ID по
# подписи/подсказке (новый интерфейс «ID, IP address, or hostname» / «Enter end user's ID, IP, or hostname», старый «Partner ID»),
# вставляем ID через ValuePattern и нажимаем «Connect» через InvokePattern; ищем по ролям и подписям, не по координатам.
# Кнопки отмены/отказа/закрытия не нажимаются никогда. Пока открыто окно хода подключения — ожидание продлевается (до двух сроков).
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
$password = $reader.ReadLine()
$timeoutMs = [double]$options.timeoutMs
$started = [DateTime]::UtcNow
$deadline = $started.AddMilliseconds($timeoutMs)
$limit = $started.AddMilliseconds($timeoutMs * 2)
$partnerId = [string]$options.id
$digits = $partnerId -replace '\D', ''
$noPassword = [bool]$options.noPassword
$SettleMs = 2000
$graceUntil = $started.AddMilliseconds([Math]::Min(4000, $timeoutMs / 3))
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

# Все окна TeamViewer, открытые до запуска: окно прежнего сеанса не может подтвердить новый.
$knownWindows = New-Object System.Collections.Generic.HashSet[int]

function Get-TeamViewerIds { @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'TeamViewer*' } | ForEach-Object { $_.Id }) }

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

# Кнопка «Connect» рядом с полем ID: сначала в ближайших предках поля, потом во всём окне. Кнопки отмены/закрытия исключены.
function Find-ConnectButton($window, $edit) {
  $scopes = @()
  $node = $edit
  # Вверх не дальше самого окна: за его пределами — другие программы.
  for ($i = 0; $i -lt 4; $i++) {
    $node = $walker.GetParent($node)
    if (-not $node -or [System.Windows.Automation.Automation]::Compare($node, $window) -or $node.Current.ProcessId -ne $window.Current.ProcessId) { break }
    $scopes += $node
  }
  $scopes += $window
  foreach ($scope in $scopes) {
    foreach ($button in $scope.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isButton)) {
      $name = [string]$button.Current.Name
      if ($name -match $denyPattern) { continue }
      if ($name -match $connectPattern -and $button.Current.IsEnabled) { return $button }
    }
  }
  return $null
}

# Запасной путь: главный экран TeamViewer без ID. Поле ищем по подписи/подсказке, ID ставим через ValuePattern, «Connect» — Invoke.
function Submit-PartnerId($ids) {
  if (-not $partnerId) { return $false }
  foreach ($window in Get-TeamViewerWindows $ids) {
    foreach ($edit in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isEdit)) {
      try {
        if ($edit.Current.IsPassword -or -not $edit.Current.IsEnabled) { continue }
        if ((Get-Labels $edit) -notmatch $idFieldPattern) { continue }
        $button = Find-ConnectButton $window $edit
        if (-not $button) { continue }
        $value = $null; $invoke = $null
        if (-not $edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$value)) { continue }
        if (-not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) { continue }
        if ($value.Current.IsReadOnly) { continue }
        $value.SetValue($partnerId)
        $invoke.Invoke()
        return $true
      } catch { continue }
    }
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
  $sawProcess = $false
  while ([DateTime]::UtcNow -lt $deadline) {
    $now = [DateTime]::UtcNow
    $ids = Get-TeamViewerIds
    if ($ids.Count) {
      $sawProcess = $true
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
        if (Submit-PartnerId $ids) {
          $submitted = $true
          Emit 'idSubmitted'
          $deadline = Get-Extended ([DateTime]::UtcNow.AddMilliseconds($timeoutMs))
        }
      }
    }
    if (($tick++ % 4) -eq 0) { Emit 'waiting' }
    Start-Sleep -Milliseconds 250
  }
  # Ни окна пароля, ни сеанса: TeamViewer запущен — "noPrompt"; процесса нет вовсе — "noWindow".
  if (-not $found) { if ($sawProcess) { Emit 'noPrompt' } else { Emit 'noWindow' }; return }
  # Пароля в файле нет: окно пароля найдено, вводит пользователь.
  if ($noPassword) { Emit 'passwordNeeded'; return }

  $pid2 = $found.Window.Current.ProcessId
  $process = Get-Process -Id $pid2
  if ($process.ProcessName -notlike 'TeamViewer*') { Emit 'focusLost'; return }
  if ([MuNative]::Elevated($pid2) -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Emit 'elevated'; return }

  # Фокус: окно пароля должно быть на переднем плане и принадлежать TeamViewer; иначе одна попытка вернуть, потом отказ.
  $handle = [IntPtr]$found.Window.Current.NativeWindowHandle
  $foreground = { $owner = 0; [void][MuNative]::GetWindowThreadProcessId([MuNative]::GetForegroundWindow(), [ref]$owner); [int]$owner }
  if ((& $foreground) -ne $pid2) { [void][MuNative]::SetForegroundWindow($handle); Start-Sleep -Milliseconds 200 }
  if ((& $foreground) -ne $pid2) { Emit 'focusLost'; return }

  $pattern = $null
  if (-not $found.Edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) { Emit 'fieldNotFound'; return }
  $pattern.SetValue($password)
  $password = $null

  # Подтвердить: кнопка по умолчанию окна (OK / Войти / Log On), иначе Enter — только пока окно пароля на переднем плане.
  $button = $null
  foreach ($candidate in $found.Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isButton)) {
    if ($candidate.Current.Name -match '^(OK|ОК|Log ?On|Войти|Увійти|Anmelden)$') { $button = $candidate; break }
  }
  if ($button) { $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
  elseif ((& $foreground) -eq $pid2) { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') }
  else { Emit 'focusLost'; return }

  # Окно пароля осталось (или появилось снова) — пароль не принят.
  Start-Sleep -Milliseconds 2500
  $again = Find-PasswordField (Get-TeamViewerIds)
  if ($again) { Emit 'wrongPassword' } else { Emit 'entered' }
} catch {
  Emit 'fieldNotFound'
} finally {
  $password = $null
}
