# Секрет в буфер обмена Windows так, чтобы он НЕ попал в журнал буфера (Win+V) и в облачную синхронизацию: вместе с текстом
# кладутся форматы ExcludeClipboardContentFromMonitorProcessing (мониторы буфера и журнал его пропускают), CanIncludeInClipboardHistory
# = 0 и CanUploadToCloudClipboard = 0 (DWORD). Electron так не умеет: каждая его запись в буфер сначала очищает буфер, текст и эти
# форматы вместе не положить. Вход: stdin — секрет в UTF-8 целиком (в аргументах его нет). Выход: одна строка JSON {"state":"ok"}.
# Секрет не пишется ни в вывод, ни в файлы. Файл — UTF-8 с BOM (Windows PowerShell 5.1 читает .ps1 без BOM в кодировке ANSI).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
$text = $reader.ReadToEnd()
try {
  if (-not $text) { exit 2 }
  $data = New-Object System.Windows.Forms.DataObject
  $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $text)
  $zero = [BitConverter]::GetBytes([int]0)
  $data.SetData('ExcludeClipboardContentFromMonitorProcessing', (New-Object System.IO.MemoryStream(, $zero)))
  $data.SetData('CanIncludeInClipboardHistory', (New-Object System.IO.MemoryStream(, $zero)))
  $data.SetData('CanUploadToCloudClipboard', (New-Object System.IO.MemoryStream(, $zero)))
  # copy=true — данные остаются в буфере после выхода процесса; 5 попыток по 100 мс, если буфер занят другой программой.
  [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 5, 100)
  [Console]::Out.WriteLine('{"state":"ok"}'); [Console]::Out.Flush()
} catch {
  exit 1
} finally {
  $text = $null; $data = $null
}
