# Ввод пароля в окно «Аутентификация» TeamViewer через UI Automation. Вход: stdin — строка 1: параметры JSON {"timeoutMs":N},
# строка 2: пароль (в аргументах командной строки пароля нет). Выход: строки JSON {"state":"waiting"} … {"state":"entered"}
# | "noWindow" | "noPrompt" | "elevated" | "focusLost" | "fieldNotFound" | "wrongPassword". Пароль не пишется ни в вывод, ни в файлы.
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
$deadline = [DateTime]::UtcNow.AddMilliseconds([double]$options.timeoutMs)
$root = [System.Windows.Automation.AutomationElement]::RootElement
$isEdit = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
$isButton = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)

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

try {
  # Запоминаем уже открытые окна пароля и сообщаем «готов»: TeamViewer запускается только после этого.
  foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    if ((Get-TeamViewerIds) -contains $window.Current.ProcessId) {
      foreach ($edit in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isEdit)) { if ($edit.Current.IsPassword) { [void]$baseline.Add([int]$window.Current.NativeWindowHandle) } }
    }
  }
  Emit 'ready'
  $found = $null
  $sawProcess = $false
  $tick = 0
  while ([DateTime]::UtcNow -lt $deadline) {
    $ids = Get-TeamViewerIds
    if ($ids.Count) { $sawProcess = $true; $found = Find-PasswordField $ids; if ($found) { break } }
    if (($tick++ % 4) -eq 0) { Emit 'waiting' }
    Start-Sleep -Milliseconds 250
  }
  # TeamViewer запущен, но окна пароля нет — вход по сохранённому доступу (или ещё грузится): noPrompt; процесса нет вовсе — noWindow.
  if (-not $found) { if ($sawProcess) { Emit 'noPrompt' } else { Emit 'noWindow' }; return }

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
