<#
================================================================================
 backup.ps1 - backup / restore / clone a Keenetic USB flash drive, Windows
================================================================================

 What it does:
   Orchestrates flash backup via WSL2. It does NOT touch the disk itself - it
   brings the USB disk into WSL and runs backup-linux.sh there (the same script
   used for native Linux). Single source of truth = backup-linux.sh.

 The image (.kbak = tar.gz: mbr.bin + opkg.e2img + meta.txt) is identical to the
 macOS/Linux format, so images are interchangeable across all three platforms.

 Disk passthrough path (auto-detected, same as prepare.ps1):
   - Windows 11 : native  wsl --mount --bare \\.\PHYSICALDRIVE<N>
   - Windows 10 : usbipd-win + attach (auto BUSID by VID:PID, single attach + retries)

 Modes:
   -Mode backup   snap the flash to a .kbak file (saved on Windows)
   -Mode restore  write a .kbak back onto a flash (WIPES it)
   -Mode clone    snap one flash and immediately write it onto another
   (no -Mode -> interactive menu)

 Requirements: Windows 10/11 x64, administrator rights (self-elevates via UAC),
               virtualization enabled in BIOS. Internet in WSL only needed the
               first time (to apt-install e2fsprogs/util-linux); afterwards none.

 Run:  right-click -> "Run with PowerShell"
       or:  powershell -ExecutionPolicy Bypass -File .\backup.ps1 -Mode backup

 WARNING: restore/clone COMPLETELY WIPE the target flash drive.
================================================================================
#>

[CmdletBinding()]
param(
  [ValidateSet("","backup","restore","clone")]
  [string]$Mode = "",
  [string]$InFile = "",        # restore: path to .kbak (if empty - chooser)
  [string]$OutDir = "",        # backup: where to save .kbak (default - beside script)
  [string]$LinuxScript = "",   # path to backup-linux.sh; if empty - beside or from git
  [switch]$DryRun,             # pass DRY_RUN=1 (nothing written to disk)
  [switch]$NoShrink,           # pass NO_SHRINK=1 (do not shrink fs before imaging)
  [switch]$KeepWslDns          # do not touch WSL DNS even if there is no internet
)

$ErrorActionPreference = "Stop"
$env:WSL_UTF8 = "1"
# Вывод WSL/bash — UTF-8; без этого русский текст в консоли идёт кракозябрами.
try {
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
  $OutputEncoding = [System.Text.UTF8Encoding]::new()
} catch { }
$RepoRaw = "https://raw.githubusercontent.com/lastik9/keenetic-entware/main/backup-linux.sh"
$Distro  = "Ubuntu"
$TmpDir  = "C:\Temp"           # latin path - bypass cyrillic in the user name

# ---------------------------------------------------------------- output
function Info($m){ Write-Host "[i] $m" -ForegroundColor Cyan }
function Ok  ($m){ Write-Host "[v] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m" -ForegroundColor Yellow }
function Die ($m){ Write-Host "[x] $m" -ForegroundColor Red; Read-Host "Enter для выхода"; exit 1 }

# usbipd пишет info/warning в stderr; под ErrorActionPreference=Stop это роняет скрипт.
function Invoke-Usbipd {
  $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  try { & usbipd.exe @args 2>&1 | ForEach-Object { Write-Host $_ } }
  finally { $ErrorActionPreference = $old }
}

# ---------------------------------------------------------------- 0. admin + UAC
function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
  Info "Требуются права администратора - перезапускаюсь через UAC..."
  $argList = @("-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"")
  if ($Mode)         { $argList += @("-Mode",$Mode) }
  if ($InFile)       { $argList += @("-InFile","`"$InFile`"") }
  if ($OutDir)       { $argList += @("-OutDir","`"$OutDir`"") }
  if ($LinuxScript)  { $argList += @("-LinuxScript","`"$LinuxScript`"") }
  if ($DryRun)       { $argList += "-DryRun" }
  if ($NoShrink)     { $argList += "-NoShrink" }
  if ($KeepWslDns)   { $argList += "-KeepWslDns" }
  Start-Process powershell -Verb RunAs -ArgumentList $argList
  exit
}

Write-Host ""
Write-Host "=== Бэкап/restore/clone флешки Keenetic - Windows/WSL ===" -ForegroundColor White
Write-Host ""

# ---------------------------------------------------------------- Windows version
$win = [System.Environment]::OSVersion.Version
$IsWin11 = ($win.Build -ge 22000)
if ($IsWin11) { Info "Windows 11 (build $($win.Build)) - путь: wsl --mount" }
else          { Info "Windows 10 (build $($win.Build)) - путь: usbipd" }

# env-строки для DRY_RUN/NO_SHRINK (подставляются в bash-команду)
$DR = if ($DryRun)   { "1" } else { "0" }
$NS = if ($NoShrink) { "1" } else { "0" }

# ---------------------------------------------------------------- 1. WSL2 + Ubuntu
function Ensure-Wsl {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Die "Не найден wsl.exe. Установи WSL: 'wsl --install' и перезагрузись, затем повтори."
  }
  # wsl.exe пишет в UTF-16 и в stderr; при ErrorActionPreference=Stop прямой вызов
  # роняет скрипт непонятной ошибкой. Проверяем состояние аккуратно, по коду возврата.
  $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  try {
    $status   = (& wsl.exe --status  2>&1 | Out-String)
    $statusRc = $LASTEXITCODE
    $verText  = (& wsl.exe --version 2>&1 | Out-String)
  } finally { $ErrorActionPreference = $old }

  # Признак «WSL не установлен/выключен»: ненулевой код и/или совет '--install' в выводе.
  if ($statusRc -ne 0 -or $status -match '--install' -or $verText -match '--install') {
    Warn "Подсистема Windows для Linux (WSL) не установлена или отключена на этой машине."
    Write-Host ""
    Write-Host "Установи её ОДНОЙ командой в этом же окне (админ):" -ForegroundColor Cyan
    Write-Host "    wsl --install -d Ubuntu" -ForegroundColor White
    Write-Host ""
    Write-Host "Затем ПЕРЕЗАГРУЗИ компьютер, доведи первичную настройку Ubuntu" -ForegroundColor Cyan
    Write-Host "(логин/пароль) и запусти backup.ps1 снова." -ForegroundColor Cyan
    Die "Нужен установленный WSL - см. инструкцию выше."
  }

  $installed = $null
  $ErrorActionPreference = "Continue"
  try {
    $installed = (wsl.exe -l -q 2>$null) |
      ForEach-Object { ($_ -replace "`0","").Trim() } |
      Where-Object { $_ -eq $Distro }
  } finally { $ErrorActionPreference = $old }
  if (-not $installed) {
    Info "Ставлю $Distro (через --web-download, минуя Store)..."
    wsl.exe --install -d $Distro --web-download | Out-Host
    Warn "Если открылось окно настройки Ubuntu (логин/пароль) - заверши его, потом снова запусти backup.ps1."
    Info "Если WSL попросил перезагрузку - перезагрузись и запусти backup.ps1 заново."
    Read-Host "Когда Ubuntu настроена и готова - нажми Enter, чтобы продолжить"
  }
  $probe = (wsl.exe -d $Distro -u root -- bash -c "echo wsl_ok") 2>$null
  if ($probe -notmatch "wsl_ok") { Die "$Distro не отвечает. Проверь установку WSL и повтори." }
  Ok "$Distro готов."
}

# keep WSL alive (background sleep) so usbipd/attach doesn't lose the VM (важно для clone: живёт через смену флешки)
# usbipd на отказе говорит прямо: "There is no WSL 2 distribution running; keep a
# command prompt to a WSL 2 distribution open to leave it running."
# ВАЖНО: разовый 'wsl -- <cmd>' (функция Wsl ниже) дистрибутив НЕ удерживает -
# поднимает и гасит через несколько секунд. Держит только процесс ниже.
$script:WslKeepAlive = $null

# Дистрибутив реально числится запущенным? ($env:WSL_UTF8=1 задан выше - вывод чистый)
function Test-WslRunning {
  $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  $running = @()
  try {
    $running = (& wsl.exe -l --running -q 2>$null | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
  } catch { $running = @() } finally { $ErrorActionPreference = $old }
  return [bool]($running -contains $Distro)
}

function Start-WslKeepAlive {
  $script:WslKeepAlive = Start-Process wsl -PassThru -WindowStyle Hidden `
    -ArgumentList "-d",$Distro,"-u","root","--","sleep","3600"
}

# Проверять ПЕРЕД каждой попыткой attach. Держатель мог не стартовать, умереть,
# попасть под чужой 'wsl --shutdown' или досидеть свой sleep. Для clone особенно:
# второй attach (мишень) идёт уже после долгой фазы backup источника.
function Assert-WslKeepAlive {
  $procAlive = ($null -ne $script:WslKeepAlive) -and (-not $script:WslKeepAlive.HasExited)
  if ($procAlive -and (Test-WslRunning)) { return }

  if (-not $procAlive) { Warn "Держатель WSL не запущен (процесс вышел) - поднимаю заново." }
  else { Warn "Держатель WSL жив как процесс, но $Distro не числится запущенным - поднимаю заново." }

  Stop-WslKeepAlive
  Start-WslKeepAlive
  Start-Sleep -Seconds 2
  if (-not (Test-WslRunning)) {
    Die "Не удалось удержать $Distro запущенным - usbipd attach не к чему цеплять. Проверь вручную: wsl -l --running"
  }
  Ok "Держатель WSL поднят, $Distro запущен."
}

function Stop-WslKeepAlive {
  if ($script:WslKeepAlive -and -not $script:WslKeepAlive.HasExited) {
    Stop-Process -Id $script:WslKeepAlive.Id -Force -ErrorAction SilentlyContinue
  }
  $script:WslKeepAlive = $null
}

# run a bash string in WSL, return stdout
function Wsl([string]$cmd) { wsl.exe -d $Distro -u root -- bash -c $cmd }

# ---------------------------------------------------------------- 2. internet/DNS (только если нет инструментов)
function Ensure-WslNet {
  Info "Проверяю интернет в WSL..."
  $host2 = "deb.debian.org"
  $ip = (Wsl "getent hosts $host2 2>/dev/null | awk '{print `$1; exit}'").Trim()
  $bad = (-not $ip) -or ($ip -like "198.18.*")
  if (-not $bad) { Ok "Интернет в WSL работает ($host2 -> $ip)."; return }
  if ($KeepWslDns) { Warn "Интернет в WSL недоступен, но -KeepWslDns задан - не трогаю DNS."; return }

  Warn "Интернет в WSL недоступен (DNS перехвачен прокси/VPN или роутером: '$ip')."
  Write-Host "    Можно прописать WSL публичный DNS (1.1.1.1 + 77.88.8.8)." -ForegroundColor Yellow
  Write-Host "    Это НЕ меняет настройки Windows и касается только WSL." -ForegroundColor Yellow
  $ans = Read-Host "    Прописать DNS в WSL? (y/n)"
  if ($ans -notmatch '^[yY]') { Die "Без интернета в WSL не установить e2fsprogs. Прерываю." }

  Wsl "printf '[network]\ngenerateResolvConf=false\n' > /etc/wsl.conf" | Out-Null
  wsl.exe --shutdown | Out-Null
  Start-Sleep -Seconds 2
  Wsl "rm -f /etc/resolv.conf; printf 'nameserver 1.1.1.1\nnameserver 77.88.8.8\n' > /etc/resolv.conf" | Out-Null
  Start-WslKeepAlive
  $ip2 = (Wsl "getent hosts $host2 2>/dev/null | awk '{print `$1; exit}'").Trim()
  if ((-not $ip2) -or ($ip2 -like "198.18.*")) { Die "DNS-фикс не помог ($host2 -> '$ip2'). Проверь сеть/прокси." }
  Ok "DNS в WSL исправлен ($host2 -> $ip2)."
}

# Интернет нужен ТОЛЬКО если в WSL ещё нет e2fsprogs/util-linux. Иначе backup работает офлайн.
function Ensure-WslTools {
  $have = (Wsl "command -v e2image >/dev/null 2>&1 && command -v sfdisk >/dev/null 2>&1 && echo yes").Trim()
  if ($have -eq "yes") { Ok "Инструменты в WSL на месте (e2fsprogs/util-linux) - интернет не нужен."; return }
  Warn "В WSL нет e2fsprogs/util-linux - для их установки нужен интернет (apt, разово)."
  Ensure-WslNet
}

# ---------------------------------------------------------------- 3. deliver backup-linux.sh
function Deliver-Script {
  New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
  $localCopy = Join-Path $TmpDir "backup-linux.sh"
  $src = $null
  if ($LinuxScript -and (Test-Path $LinuxScript)) { $src = $LinuxScript }
  else {
    $near = Join-Path $PSScriptRoot "backup-linux.sh"
    if (Test-Path $near) { $src = $near }
  }
  if ($src) {
    Info "Беру backup-linux.sh рядом: $src"
    if ((Resolve-Path $src).Path -ne (Resolve-Path -LiteralPath $localCopy -ErrorAction SilentlyContinue).Path) {
      Copy-Item $src $localCopy -Force
    } else { Info "Файл уже в $TmpDir - копирование не нужно." }
  } else {
    Info "backup-linux.sh рядом не найден - качаю с гита..."
    try { Invoke-WebRequest -Uri $RepoRaw -OutFile $localCopy -UseBasicParsing }
    catch { Die "Не удалось скачать backup-linux.sh с $RepoRaw. Положи файл рядом с backup.ps1 и повтори." }
  }
  Wsl "cp /mnt/c/Temp/backup-linux.sh /root/ && sed -i 's/\r`$//' /root/backup-linux.sh && chmod +x /root/backup-linux.sh && echo ok" | Out-Null
  Ok "backup-linux.sh доставлен в WSL."
}

# ---------------------------------------------------------------- 4. choose flash drive (Windows)
#   $forWrite=$true  -> цель для restore/clone: предупреждаем о СТИРАНИИ, требуем 'YES'.
#   $forWrite=$false -> источник для backup: только читаем, лёгкое подтверждение.
function Choose-UsbDisk([bool]$forWrite, [string]$title) {
  $disks = Get-Disk | Where-Object { $_.BusType -eq "USB" -and $_.Size -gt 0 }
  if (-not $disks) { Die "USB-накопители не найдены. Вставь флешку и повтори." }
  Write-Host ""
  Write-Host $title -ForegroundColor Cyan
  $i = 1; $map = @{}
  foreach ($d in $disks) {
    $gb = [math]::Round($d.Size/1GB,1)
    Write-Host ("  {0}) Disk {1} - {2} - {3} GB" -f $i,$d.Number,$d.FriendlyName,$gb) -ForegroundColor Green
    $map[$i] = $d; $i++
  }
  Write-Host ""
  $sel = Read-Host "Номер флешки (или q)"
  if ($sel -eq "q") { exit 0 }
  $disk = $map[[int]$sel]
  if (-not $disk) { Die "Некорректный выбор." }
  if ($disk.IsBoot -or $disk.IsSystem) { Die "Выбран системный/загрузочный диск. Отказ." }
  $gb = [math]::Round($disk.Size/1GB,1)
  if ($forWrite) {
    Warn "Диск $($disk.Number) ($($disk.FriendlyName), $gb GB) будет ПОЛНОСТЬЮ СТЁРТ."
    # -cne, а НЕ -ne: обычный -ne в PowerShell регистронезависим, и 'yes' проходило бы.
    $c = Read-Host "Введи 'YES' (заглавными) для подтверждения"
    if ($c -cne "YES") { Die "Не подтверждено. Отмена." }
  } else {
    Info "Источник: Disk $($disk.Number) ($($disk.FriendlyName), $gb GB) - только чтение."
    $c = Read-Host "Это нужная флешка? (y/n)"
    if ($c -notmatch '^[yY]') { Die "Отмена." }
  }
  return $disk
}

# ---------------------------------------------------------------- 5. passthrough (как в prepare.ps1)
# ВАЖНО: вывод wsl.exe нельзя оставлять "голым" — он утечёт в возвращаемое значение
# функции, и вместо $false вернётся массив (истинный!), из-за чего fallback не сработает.
# Поэтому весь вывод ловим в переменную и печатаем через Write-Host.
function Attach-Win11([int]$diskNumber, $disk) {
  # Проверено на живой Win11 (build 26200): для СЪЁМНЫХ USB-флешек wsl --mount --bare
  # стабильно падает с Wsl/Service/AttachDisk/MountDisk/HCS/0x8007000f (ERROR_INVALID_DRIVE).
  # Нативный путь годится для нес'ёмных дисков; для флешек сразу идём в usbipd.
  $removable = $false
  try {
    $dd = Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Where-Object { $_.Index -eq $diskNumber }
    if ($dd -and $dd.MediaType -match 'Removable') { $removable = $true }
  } catch { }
  if ($removable) {
    Info "Съёмный USB-накопитель: wsl --mount для таких не работает (0x8007000f) - иду через usbipd."
    return $false
  }

  $path = "\\.\PHYSICALDRIVE$diskNumber"
  Info "Пробрасываю $path в WSL (wsl --mount --bare)..."
  $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  $out = ""; $rc = 1
  try {
    $out = (& wsl.exe --mount --bare $path 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $rc = $LASTEXITCODE
  } finally { $ErrorActionPreference = $old }
  if ($out) { Write-Host $out }
  if ($rc -ne 0) {
    Warn "wsl --mount не сработал (код $rc) - пробую usbipd (как на Win10)..."
    return $false
  }
  Start-Sleep -Seconds 2
  return $true
}

function Ensure-Usbipd {
  if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    Info "Ставлю usbipd-win (winget)..."
    try { winget install --exact --id dorssel.usbipd-win --accept-source-agreements --accept-package-agreements | Out-Host }
    catch { Die "Не удалось поставить usbipd. Установи вручную: https://github.com/dorssel/usbipd-win/releases и повтори." }
    if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
      Die "usbipd установлен, но не в PATH. Перезапусти PowerShell и запусти backup.ps1 снова."
    }
  }
  $svc = Get-Service usbipd -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -ne "Running") {
    Info "Запускаю службу usbipd..."
    try { Start-Service usbipd } catch { Warn "Не смог запустить службу usbipd: $_" }
    Start-Sleep -Seconds 1
    $svc = Get-Service usbipd -ErrorAction SilentlyContinue
  }
  # Свежеустановленный usbipd не работает до перезагрузки: без этой проверки скрипт
  # молотит 5 бесполезных ретраев attach и падает по таймауту с непонятной ошибкой.
  if (-not $svc -or $svc.Status -ne "Running") {
    Write-Host ""
    Warn "Служба usbipd установлена, но не запущена - так бывает сразу после её установки."
    Write-Host "    ПЕРЕЗАГРУЗИ компьютер и запусти backup.ps1 снова." -ForegroundColor Cyan
    Die "Нужна перезагрузка после установки usbipd."
  }
}

$script:UsbipBusid = $null

function Get-DiskUsbId($disk) {
  try {
    $dd = Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Where-Object { $_.Index -eq $disk.Number }
    if (-not $dd) { return $null }
    $parent = (Get-PnpDeviceProperty -InstanceId $dd.PNPDeviceID -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data
    if ($parent -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
      return ("{0}:{1}" -f $matches[1],$matches[2]).ToLower()
    }
  } catch { }
  return $null
}
function Get-UsbipdListLines {
  $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  try { return (& usbipd.exe list 2>&1 | ForEach-Object { "$_" }) }
  finally { $ErrorActionPreference = $old }
}
function Attach-Usbipd($disk) {
  Ensure-Usbipd
  $busid = $null
  $want = Get-DiskUsbId $disk
  $lines = Get-UsbipdListLines
  if ($want) {
    $hits = @()
    foreach ($ln in $lines) {
      if ($ln -match '^\s*(\d+-\d+)\s+([0-9A-Fa-f]{4}:[0-9A-Fa-f]{4})') {
        if ($matches[2].ToLower() -eq $want) { $hits += $matches[1] }
      }
    }
    if ($hits.Count -eq 1) { $busid = $hits[0]; Ok "Флешка определена автоматически: BUSID $busid (USB $want)" }
    elseif ($hits.Count -gt 1) { Warn "Несколько USB-устройств с ID $want - выбери BUSID вручную." }
  }
  if (-not $busid) {
    Info "Не удалось определить BUSID автоматически. Найди свою флешку в списке (столбец BUSID):"
    $lines | ForEach-Object { Write-Host $_ }
    $busid = Read-Host "Введи BUSID флешки (напр. 11-4)"
    if ($busid -notmatch '^\d+-\d+$') { Die "BUSID '$busid' не похож на правильный (формат N-N)." }
  }
  $script:UsbipBusid = $busid

  # modprobe — разовая команда. WSL живым держит НЕ она, а $script:WslKeepAlive.
  Info "modprobe usb-storage/uas..."
  Wsl "modprobe usb-storage; modprobe uas; echo ok" | Out-Null
  Invoke-Usbipd bind --busid $busid

  # Успех определяем ТОЛЬКО по коду возврата (проверено вживую: RC=0 успех,
  # RC=1 отказ) — как в блоке 'wsl --mount' выше. Поиск слов в тексте
  # ('error|failed|state') не годится: 'state' встречается в безобидном выводе,
  # а настоящая причина отказа при этом выбрасывалась и диагностика шла вслепую.
  # Число попыток: 10, паузы нарастающие. Обоснование — факт, не теория:
  # на здоровой отлаженной Win10 attach поехал с 5-й попытки ИЗ ПЯТИ (запас нулевой),
  # ручное воспроизведение следом дало 3-ю из 3. Разброс 1..5 при 'Device in error state'.
  # Это флак устройства/контроллера, он ретраебельный и одинаковыми паузами не лечится.
  $maxAttempts = 10
  $retryDelays = @(3, 3, 5, 5, 8, 8, 12, 12, 15)   # пауза ПОСЛЕ попытки $a -> индекс $a-1
  Info "Прицепляю флешку к WSL (attach с повторами)..."
  $attached = $false
  for ($a = 1; $a -le $maxAttempts; $a++) {
    Assert-WslKeepAlive     # без запущенного дистрибутива attach бессмыслен
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $out = (& usbipd.exe attach --wsl --busid $busid 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $rc  = $LASTEXITCODE
    $ErrorActionPreference = $old

    if ($out) { Write-Host $out }   # usbipd называет причину внятно — не выбрасывать
    if ($rc -eq 0) { $attached = $true; Ok "attach прошёл с попытки $a (RC=0)."; break }

    Warn "Попытка $a из $maxAttempts не удалась (RC=$rc)."
    # 'Device in error state' — НЕ повод выходить из цикла: устройство просто флакует,
    # лечится повтором. Раньше времени не сдаёмся, идём до $maxAttempts.
    # 'already attached' — НЕ успех: привязка может висеть от умершего экземпляра
    # WSL, а устройства в живом при этом нет. Отцепляем и пробуем заново.
    if ($out -match 'already attached') {
      Info "usbipd считает устройство уже прицепленным - отцепляю и повторяю."
      $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
      & usbipd.exe detach --busid $busid 2>&1 | ForEach-Object { Write-Host $_ }
      $ErrorActionPreference = $old
      Start-Sleep -Seconds 2
      continue
    }
    if ($a -lt $maxAttempts) {
      $wait = $retryDelays[$a - 1]
      Info "Повтор через $wait c..."
      Start-Sleep -Seconds $wait
    }
  }
  if (-not $attached) {
    Warn "usbipd об успехе не отчитался - проверяю, появилось ли устройство фактически."
    Start-Sleep -Seconds 2
  }

  Info "Жду, пока ядро создаст блочное устройство..."
  $found = $false
  for ($t=0; $t -lt 20; $t++) {
    Start-Sleep -Seconds 2
    $has = (Wsl "lsblk -dpno NAME,SIZE,TYPE,MODEL | grep -i disk | grep -iv 'Virtual Disk'") 2>$null
    if ($has -match "sd") { $found = $true; break }
  }
  if (-not $found) { Die "Флешка не появилась в WSL за ~40 c. Причину смотри в тексте usbipd выше. Если ошибок там нет - передёрни флешку/USB-порт и повтори." }
  Ok "Флешка в WSL."
  return $true
}
function Detach-Usbipd {
  Get-Process usbipd -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID } | Stop-Process -Force -ErrorAction SilentlyContinue
  if ($script:UsbipBusid) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
      & usbipd.exe detach --busid $script:UsbipBusid 2>&1 | Out-Null
      & usbipd.exe unbind --busid $script:UsbipBusid 2>&1 | Out-Null
    } finally { $ErrorActionPreference = $old }
    $script:UsbipBusid = $null
  }
}

# ---------------------------------------------------------------- 6. disk name in WSL (как в prepare.ps1)
function Find-WslDisk([double]$sizeBytes) {
  $targetGB = [math]::Round($sizeBytes/1GB,1)
  $cand = @()
  for ($try = 0; $try -lt 15; $try++) {
    $raw = (Wsl "lsblk -dbpno NAME,SIZE,TYPE,MODEL") 2>$null
    $cand = @()
    foreach ($ln in ($raw -split "`n")) {
      $t = $ln.Trim(); if (-not $t) { continue }
      if ($t -match '^(\S+)\s+(\d+)\s+(\S+)\s*(.*)$') {
        $name=$matches[1]; $bytes=[double]$matches[2]; $type=$matches[3]; $model=$matches[4].Trim()
        if ($type -ne "disk") { continue }
        if ($model -match 'Virtual Disk') { continue }
        $cand += [pscustomobject]@{ Name=$name; GB=[math]::Round($bytes/1GB,1); Model=$model; Bytes=$bytes }
      }
    }
    if ($cand.Count -ge 1) { break }
    Start-Sleep -Seconds 2
  }
  if ($cand.Count -eq 0) { Die "Не нашёл флешку в WSL за ~30 c (все диски - Virtual Disk). Передёрни флешку и повтори." }
  if ($cand.Count -eq 1) { $pick = $cand[0] }
  else {
    $pick = $cand | Sort-Object { [math]::Abs($_.Bytes - $sizeBytes) } | Select-Object -First 1
    Warn "Кандидатов несколько, выбрал ближайший по размеру: $($pick.Name) ($($pick.GB)GB, $($pick.Model))"
  }
  $diff = [math]::Abs($pick.Bytes - $sizeBytes) / $sizeBytes
  if ($diff -gt 0.15) {
    Warn "Размер найденного диска $($pick.Name) ($($pick.GB)GB) заметно отличается от выбранного (~${targetGB}GB)."
    $ok = Read-Host "Это точно твоя флешка $($pick.Name)? (y/n)"
    if ($ok -notmatch '^[yY]') { Die "Отмена - устройство не подтверждено." }
  }
  return $pick.Name
}

# ---------------------------------------------------------------- attach/detach lifecycle helpers
function Attach-Disk($disk) {
  $useMount = $false
  if ($IsWin11) { $useMount = Attach-Win11 $disk.Number $disk }
  if (-not $useMount) { Attach-Usbipd $disk | Out-Null }
  $dev = Find-WslDisk $disk.Size
  Ok "Целевое устройство в WSL: $dev"
  return @{ Dev = $dev; UseMount = $useMount }
}
function Detach-Disk($disk, [bool]$useMount) {
  if ($useMount) {
    try { wsl.exe --unmount "\\.\PHYSICALDRIVE$($disk.Number)" 2>$null } catch {}
  } else { Detach-Usbipd }
}

# ---------------------------------------------------------------- WSL runners
function Invoke-BackupInWsl([string]$dev, [string]$wslOut) {
  Info "Снимаю образ (backup-linux.sh)..."
  Write-Host ("-"*70)
  wsl.exe -d $Distro -u root -- bash -c "cd /root && DRY_RUN=$DR NO_SHRINK=$NS KBAK_OUT='$wslOut' DEV=$dev ASSUME_YES=1 bash backup-linux.sh backup"
  $rc = $LASTEXITCODE
  Write-Host ("-"*70)
  if ($rc -ne 0) { Die "backup-linux.sh backup завершился с ошибкой (код $rc)." }
}
function Invoke-RestoreInWsl([string]$dev, [string]$wslKbak) {
  Info "Разворачиваю образ (backup-linux.sh restore)..."
  Write-Host ("-"*70)
  wsl.exe -d $Distro -u root -- bash -c "cd /root && DRY_RUN=$DR DEV=$dev ASSUME_YES=1 bash backup-linux.sh restore '$wslKbak'"
  $rc = $LASTEXITCODE
  Write-Host ("-"*70)
  if ($rc -ne 0) { Die "backup-linux.sh restore завершился с ошибкой (код $rc). Флешку не извлекаю." }
}

# stage a Windows .kbak into C:\Temp so WSL sees it at /mnt/c/Temp/... (robust vs any drive/cyrillic)
function Stage-KbakToWsl([string]$winPath) {
  New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $tmp = Join-Path $TmpDir "restore-$stamp.kbak"
  Copy-Item -LiteralPath $winPath $tmp -Force
  return @{ Win = $tmp; Wsl = "/mnt/c/Temp/restore-$stamp.kbak" }
}

# ---------------------------------------------------------------- mode menu
if (-not $Mode) {
  Write-Host "Что сделать?" -ForegroundColor Cyan
  Write-Host "  1) backup  - снять образ флешки в файл"
  Write-Host "  2) restore - записать образ из файла на флешку"
  Write-Host "  3) clone   - снять образ и сразу залить на другую флешку"
  switch (Read-Host "Номер (1/2/3)") {
    "1" { $Mode = "backup" }
    "2" { $Mode = "restore" }
    "3" { $Mode = "clone" }
    default { Die "Некорректный выбор." }
  }
}

# resolve OutDir (backup): по умолчанию рядом со скриптом
if (-not $OutDir) { $OutDir = $PSScriptRoot }

# ---------------------------------------------------------------- MAIN
Ensure-Wsl
Start-WslKeepAlive
try {
  Ensure-WslTools
  Deliver-Script

  switch ($Mode) {

    "backup" {
      $disk = Choose-UsbDisk $false "Найденные USB-накопители (СНЯТИЕ образа):"
      $att = $null
      try {
        $att = Attach-Disk $disk
        $stamp = Get-Date -Format "yyyyMMdd-HHmm"
        $name  = "keenetic-backup-$stamp.kbak"
        $wslOut = "/mnt/c/Temp/$name"
        New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
        Invoke-BackupInWsl $att.Dev $wslOut
        if (-not $DryRun) {
          New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
          $final = Join-Path $OutDir $name
          Move-Item -LiteralPath (Join-Path $TmpDir $name) $final -Force
          Ok "Образ сохранён: $final"
        } else { Info "(dry-run) файл не создавался." }
      }
      finally { if ($att) { Detach-Disk $disk $att.UseMount } }
    }

    "restore" {
      # 1) выбрать .kbak на Windows
      if ($InFile -and (Test-Path -LiteralPath $InFile)) { $kbakWin = (Resolve-Path -LiteralPath $InFile).Path }
      else {
        if ($InFile) { Warn "Файл '$InFile' не найден - выбери из списка." }
        $files = @(Get-ChildItem -Path $OutDir,$PSScriptRoot -Filter *.kbak -File -ErrorAction SilentlyContinue |
                   Sort-Object -Property FullName -Unique |
                   Sort-Object LastWriteTime -Descending)
        if ($files.Count -eq 0) {
          $kbakWin = Read-Host "Файлы .kbak рядом не найдены. Введи полный путь к .kbak"
          if (-not (Test-Path -LiteralPath $kbakWin)) { Die "Файл не найден: $kbakWin" }
        } else {
          Write-Host ""; Write-Host "Выбери образ для восстановления:" -ForegroundColor Cyan
          $i=1; $map=@{}
          foreach ($f in $files) {
            Write-Host ("  {0}) {1}  ({2:N1} MB, {3})" -f $i,$f.Name,($f.Length/1MB),$f.LastWriteTime) -ForegroundColor Green
            $map[$i]=$f.FullName; $i++
          }
          $sel = Read-Host "Номер (или p - ввести путь, q - выход)"
          if ($sel -eq "q") { exit 0 }
          if ($sel -eq "p") { $kbakWin = Read-Host "Путь к .kbak"; if (-not (Test-Path -LiteralPath $kbakWin)) { Die "Файл не найден." } }
          else { $kbakWin = $map[[int]$sel]; if (-not $kbakWin) { Die "Некорректный выбор." } }
        }
      }
      Info "Образ: $kbakWin"
      $staged = Stage-KbakToWsl $kbakWin

      # 2) выбрать целевую флешку (СТИРАНИЕ) и развернуть
      $disk = Choose-UsbDisk $true "Найденные USB-накопители (ЗАПИСЬ образа, флешка будет СТЁРТА):"
      $att = $null
      try {
        $att = Attach-Disk $disk
        Invoke-RestoreInWsl $att.Dev $staged.Wsl
        Ok "Готово! Образ развёрнут на флешку."
        Write-Host ""
        Write-Host "Дальше - на роутере:" -ForegroundColor Cyan
        Write-Host "  1. Вставь флешку в Keenetic."
        Write-Host "  2. Swap активируется на роутере (router-setup.sh: mkswap -L SWAP)."
      }
      finally {
        if ($att) { Detach-Disk $disk $att.UseMount }
        Remove-Item -LiteralPath $staged.Win -Force -ErrorAction SilentlyContinue
      }
    }

    "clone" {
      # Фаза 1: снять образ с источника в C:\Temp
      Warn "CLONE: сначала снимем образ с ИСХОДНОЙ флешки, потом зальём на ЦЕЛЕВУЮ."
      $src = Choose-UsbDisk $false "Найденные USB-накопители (ИСТОЧНИК клона):"
      $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
      $cloneWsl = "/mnt/c/Temp/clone-$stamp.kbak"
      $cloneWin = Join-Path $TmpDir "clone-$stamp.kbak"
      New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
      $attS = $null
      try {
        $attS = Attach-Disk $src
        Invoke-BackupInWsl $attS.Dev $cloneWsl
      } finally { if ($attS) { Detach-Disk $src $attS.UseMount } }
      if ($DryRun) { Info "(dry-run) фаза restore пропущена."; }
      else {
        if (-not (Test-Path -LiteralPath $cloneWin)) { Die "Образ клона не создан - отмена." }
        Ok "Образ источника снят. Теперь целевая флешка."
        Write-Host ""
        Warn "Если ОДИН USB-порт - выньте исходную флешку и вставьте ЦЕЛЕВУЮ сейчас."
        Warn "Если портов два - на след. шаге выбери именно ЦЕЛЕВУЮ (не исходную!)."
        Read-Host "Когда целевая флешка на месте - нажми Enter"

        # Фаза 2: развернуть на целевую
        $dst = Choose-UsbDisk $true "Найденные USB-накопители (ЦЕЛЬ клона, будет СТЁРТА):"
        $attD = $null
        try {
          $attD = Attach-Disk $dst
          Invoke-RestoreInWsl $attD.Dev $cloneWsl
          Ok "Готово! Флешка склонирована."
        }
        finally {
          if ($attD) { Detach-Disk $dst $attD.UseMount }
          # Образ НЕ удаляем никогда. При успехе это готовая страховка - снимок
          # рабочей системы. При провале он нужен ещё больше: источник уже
          # отсоединён, цель в непонятном состоянии, и повторить restore из
          # готового файла дешевле, чем снимать образ заново.
          # Путь печатаем ПО-ВИНДОВОМУ: сообщение читает человек в PowerShell,
          # ему этот путь вставлять в проводник (backup-linux.sh выше показал
          # /mnt/c/Temp/... - это тот же файл, просто глазами WSL).
          Write-Host ""
          Ok "Образ клона сохранён: $cloneWin"
          Info "Повторить разворот из него:  .\backup.ps1 -Mode restore -InFile $cloneWin"
          Info "Файл можно удалить вручную, если он больше не нужен."
        }
      }
    }
  }
}
finally {
  Stop-WslKeepAlive
}

Write-Host ""
Read-Host "Готово. Нажми Enter для выхода"
