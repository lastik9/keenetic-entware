<#
================================================================================
 prepare.ps1 - prepare a USB flash drive for Entware (Keenetic routers), Windows
================================================================================

 What it does:
   Orchestrates flash preparation via WSL2. It does NOT partition anything itself
   - it brings the USB disk into WSL and runs prepare-linux.sh there (the same
   script used for native Linux). Single source of truth = prepare-linux.sh.

 Disk passthrough path (auto-detected):
   - USB flash drives (removable), ANY Windows : usbipd-win + attach --auto-attach
     wsl --mount --bare does NOT work with removable media on any Windows -
     it fails with Wsl/Service/AttachDisk/MountDisk/HCS/0x8007000f
     (ERROR_INVALID_DRIVE). Verified on live Win11 build 26200, two flash drives.
   - Non-removable disks, Windows 11 : native wsl --mount --bare \\.\PHYSICALDRIVE<N>

 Requirements: Windows 10/11 x64, internet, administrator rights
               (the script self-elevates via UAC), virtualization enabled in BIOS.

 Run:  right-click -> "Run with PowerShell"
       or:  powershell -ExecutionPolicy Bypass -File .\prepare.ps1
       dry run (nothing is written to the disk):
            powershell -ExecutionPolicy Bypass -File .\prepare.ps1 -DryRun

 WARNING: the selected flash drive will be COMPLETELY WIPED.
================================================================================
#>

[CmdletBinding()]
param(
  [string]$Arch = "",          # mipsel|mips|aarch64 - if empty, we ask
  [string]$LinuxScript = "",   # path to prepare-linux.sh; if empty - beside or from git
  [switch]$DryRun,             # pass DRY_RUN=1 - nothing is written to the disk
  [switch]$KeepWslDns          # do not touch WSL DNS even if there is no internet
)

$ErrorActionPreference = "Stop"
$env:WSL_UTF8 = "1"   # make wsl.exe emit UTF-8, otherwise -l/--version come with null bytes
# Вывод WSL/bash — UTF-8; без этого русский текст в консоли идёт кракозябрами.
# ВАЖНО: запускать скрипт БЕЗ '| Tee-Object' — пайп во внешний powershell перекодирует
# байты второй раз и ломает вывод. Нужен лог — используй Start-Transcript.
try {
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
  $OutputEncoding = [System.Text.UTF8Encoding]::new()
} catch { }
$RepoRaw = "https://raw.githubusercontent.com/lastik9/keenetic-entware/main/prepare-linux.sh"
$Distro  = "Ubuntu"
$TmpDir  = "C:\Temp"           # latin path - bypass cyrillic in the user name

# ---------------------------------------------------------------- output
function Info($m){ Write-Host "[i] $m" -ForegroundColor Cyan }
function Ok  ($m){ Write-Host "[v] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m" -ForegroundColor Yellow }
function Die ($m){ Write-Host "[x] $m" -ForegroundColor Red; Read-Host "Enter для выхода"; exit 1 }

# usbipd пишет info/warning в stderr; под ErrorActionPreference=Stop это роняет скрипт.
# Хелпер запускает usbipd.exe (именно .exe, иначе рекурсия на саму функцию),
# сливая stderr в stdout и не считая это ошибкой.
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
  if ($Arch)         { $argList += @("-Arch",$Arch) }
  if ($LinuxScript)  { $argList += @("-LinuxScript","`"$LinuxScript`"") }
  if ($KeepWslDns)   { $argList += "-KeepWslDns" }
  Start-Process powershell -Verb RunAs -ArgumentList $argList
  exit
}

Write-Host ""
Write-Host "=== Подготовка флешки под Entware (Keenetic) - Windows/WSL ===" -ForegroundColor White
Write-Host ""

# ---------------------------------------------------------------- Windows version
$win = [System.Environment]::OSVersion.Version
$IsWin11 = ($win.Build -ge 22000)
# Для СЪЁМНЫХ носителей путь всегда usbipd (wsl --mount их не принимает ни на
# Win10, ни на Win11) - поэтому здесь не обещаем wsl --mount заранее.
$winName = if ($IsWin11) { "11" } else { "10" }
Info "Windows $winName (build $($win.Build)) - флешку пробрасываю через usbipd"

# ---------------------------------------------------------------- 1. WSL2 + Ubuntu
function Ensure-Wsl {
  # is the wsl engine present at all
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Die "Не найден wsl.exe. Установи WSL: 'wsl --install' и перезагрузись, затем повтори."
  }

  # WSL version (if old built-in WSL - update it)
  $null = (wsl.exe --version) 2>$null
  if ($LASTEXITCODE -ne 0) {
    Warn "Старая версия WSL. Обновляю (wsl --update)..."
    wsl.exe --update | Out-Host
  }

  # is our distro installed
  $installed = (wsl.exe -l -q) 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $Distro }
  if (-not $installed) {
    Info "Ставлю $Distro (через --web-download, минуя Store)..."
    # --web-download: on Win10 the Store download often hangs at 0%
    wsl.exe --install -d $Distro --web-download | Out-Host
    Warn "Если открылось окно настройки Ubuntu (логин/пароль) - заверши его, потом снова запусти prepare.ps1."
    Info "Если WSL попросил перезагрузку - перезагрузись и запусти prepare.ps1 заново."
    Read-Host "Когда Ubuntu настроена и готова - нажми Enter, чтобы продолжить"
  }

  # final probe that the distro responds
  $probe = (wsl.exe -d $Distro -u root -- bash -c "echo wsl_ok") 2>$null
  if ($probe -notmatch "wsl_ok") { Die "$Distro не отвечает. Проверь установку WSL и повтори." }
  Ok "$Distro готов."
}

# keep WSL alive (background sleep) so usbipd/attach doesn't lose the VM
$script:WslKeepAlive = $null
function Start-WslKeepAlive {
  $script:WslKeepAlive = Start-Process wsl -PassThru -WindowStyle Hidden `
    -ArgumentList "-d",$Distro,"-u","root","--","sleep","1800"
}
function Stop-WslKeepAlive {
  if ($script:WslKeepAlive -and -not $script:WslKeepAlive.HasExited) {
    Stop-Process -Id $script:WslKeepAlive.Id -Force -ErrorAction SilentlyContinue
  }
}

# run a bash string in WSL, return stdout
function Wsl([string]$cmd) { wsl.exe -d $Distro -u root -- bash -c $cmd }

# ---------------------------------------------------------------- 2. internet+DNS (conditional)
function Ensure-WslNet {
  Info "Проверяю интернет в WSL..."
  $host2 = "bin.entware.net"
  $ip = (Wsl "getent hosts $host2 2>/dev/null | awk '{print `$1; exit}'").Trim()

  $bad = (-not $ip) -or ($ip -like "198.18.*")   # empty or fake-ip from proxy
  if (-not $bad) {
    # resolve works - check a real download
    $probe = (Wsl "curl -fsS --max-time 8 -o /dev/null -w ok https://$host2/ 2>/dev/null").Trim()
    if ($probe -eq "ok") { Ok "Интернет в WSL работает ($host2 -> $ip)."; return }
    $bad = $true
  }

  if ($KeepWslDns) { Warn "Интернет в WSL недоступен, но -KeepWslDns задан - не трогаю DNS."; return }

  Warn "Интернет в WSL недоступен (DNS перехвачен прокси/VPN или роутером: '$ip')."
  Write-Host "    Можно прописать WSL публичный DNS (1.1.1.1 + 77.88.8.8)." -ForegroundColor Yellow
  Write-Host "    Это НЕ меняет настройки Windows и касается только WSL." -ForegroundColor Yellow
  $ans = Read-Host "    Прописать DNS в WSL? (y/n)"
  if ($ans -notmatch '^[yY]') { Die "Без интернета в WSL не скачать installer. Прерываю." }

  Wsl "printf '[network]\ngenerateResolvConf=false\n' > /etc/wsl.conf" | Out-Null
  wsl.exe --shutdown | Out-Null
  Start-Sleep -Seconds 2
  Wsl "rm -f /etc/resolv.conf; printf 'nameserver 1.1.1.1\nnameserver 77.88.8.8\n' > /etc/resolv.conf" | Out-Null
  Start-WslKeepAlive

  $ip2 = (Wsl "getent hosts $host2 2>/dev/null | awk '{print `$1; exit}'").Trim()
  if ((-not $ip2) -or ($ip2 -like "198.18.*")) { Die "DNS-фикс не помог ($host2 -> '$ip2'). Проверь сеть/прокси." }
  Ok "DNS в WSL исправлен ($host2 -> $ip2)."
}

# ---------------------------------------------------------------- 3. deliver prepare-linux.sh
function Deliver-Script {
  New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
  $localCopy = Join-Path $TmpDir "prepare-linux.sh"

  $src = $null
  if ($LinuxScript -and (Test-Path $LinuxScript)) { $src = $LinuxScript }
  else {
    $near = Join-Path $PSScriptRoot "prepare-linux.sh"
    if (Test-Path $near) { $src = $near }
  }

  if ($src) {
    Info "Беру prepare-linux.sh рядом: $src"
    if ((Resolve-Path $src).Path -ne (Resolve-Path -LiteralPath $localCopy -ErrorAction SilentlyContinue).Path) {
      Copy-Item $src $localCopy -Force
    } else {
      Info "Файл уже в $TmpDir - копирование не нужно."
    }
  } else {
    Info "prepare-linux.sh рядом не найден - качаю с гита..."
    try { Invoke-WebRequest -Uri $RepoRaw -OutFile $localCopy -UseBasicParsing }
    catch { Die "Не удалось скачать prepare-linux.sh с $RepoRaw. Положи файл рядом с prepare.ps1 и повтори." }
  }

  # copy into WSL + strip CRLF
  Wsl "cp /mnt/c/Temp/prepare-linux.sh /root/ && sed -i 's/\r`$//' /root/prepare-linux.sh && chmod +x /root/prepare-linux.sh && echo ok" | Out-Null
  Ok "prepare-linux.sh доставлен в WSL."
}

# ---------------------------------------------------------------- 4. choose architecture
function Choose-Arch {
  if ($Arch) {
    if ($Arch -notin @("mipsel","mips","aarch64")) { Die "Неверная -Arch '$Arch' (mipsel|mips|aarch64)." }
    return $Arch
  }
  Write-Host ""
  Write-Host "Архитектура процессора роутера:" -ForegroundColor Cyan
  Write-Host "  1) mipsel  - Giga(KN-1010/1011), Ultra(KN-1810), Extra, Omni, Viva, Giant, Hopper(KN-3810)..."
  Write-Host "  2) mips    - Ultra SE(KN-2510), Giga SE(KN-2410), DSL, Duo, Hopper DSL(KN-3610)..."
  Write-Host "  3) aarch64 - Peak(KN-2710), Ultra(KN-1811), Giga(KN-1012), Hopper(KN-3811/3812)"
  switch (Read-Host "Номер (1/2/3)") {
    "1" { return "mipsel" }
    "2" { return "mips" }
    "3" { return "aarch64" }
    default { Die "Некорректный выбор архитектуры." }
  }
}

# ---------------------------------------------------------------- 5. choose flash drive (Windows)
function Choose-UsbDisk {
  $disks = Get-Disk | Where-Object { $_.BusType -eq "USB" -and $_.Size -gt 0 }
  if (-not $disks) { Die "USB-накопители не найдены. Вставь флешку и повтори." }

  Write-Host ""
  Write-Host "Найденные USB-накопители:" -ForegroundColor Cyan
  $i = 1; $map = @{}
  foreach ($d in $disks) {
    $gb = [math]::Round($d.Size/1GB,1)
    Write-Host ("  {0}) Disk {1} - {2} - {3} GB" -f $i,$d.Number,$d.FriendlyName,$gb) -ForegroundColor Green
    $map[$i] = $d; $i++
  }
  Write-Host ""
  $sel = Read-Host "Номер флешки для подготовки (или q)"
  if ($sel -eq "q") { exit 0 }
  $disk = $map[[int]$sel]
  if (-not $disk) { Die "Некорректный выбор." }

  # safety: not a system/boot disk
  if ($disk.IsBoot -or $disk.IsSystem) { Die "Выбран системный/загрузочный диск. Отказ." }
  $gb = [math]::Round($disk.Size/1GB,1)
  Warn "Диск $($disk.Number) ($($disk.FriendlyName), $gb GB) будет ПОЛНОСТЬЮ СТЁРТ."
  # -cne, а НЕ -ne: обычный -ne в PowerShell регистронезависим, и 'yes' проходило бы.
  $c = Read-Host "Введи 'YES' (заглавными) для подтверждения"
  if ($c -cne "YES") { Die "Не подтверждено. Отмена." }
  return $disk
}

# ---------------------------------------------------------------- 6a. passthrough: Win11 (mount)
# ВАЖНО: вывод wsl.exe нельзя оставлять "голым" — он утечёт в возвращаемое значение
# функции, и вместо $false вернётся массив (истинный!), из-за чего fallback на usbipd
# не сработает. Весь вывод ловим в переменную и печатаем через Write-Host.
function Attach-Win11([int]$diskNumber) {
  # Проверено на живой Win11 (build 26200, 15.07.2026): для СЪЁМНЫХ USB-флешек
  # wsl --mount --bare стабильно падает с Wsl/Service/AttachDisk/MountDisk/HCS/0x8007000f
  # (ERROR_INVALID_DRIVE). Нативный путь пригоден лишь для нес'ёмных дисков —
  # для флешек сразу идём в usbipd, не тратя время на заведомо провальную попытку.
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

# ---------------------------------------------------------------- 6b. passthrough: usbipd
function Ensure-Usbipd {
  if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    Info "Ставлю usbipd-win (winget)..."
    try { winget install --exact --id dorssel.usbipd-win --accept-source-agreements --accept-package-agreements | Out-Host }
    catch { Die "Не удалось поставить usbipd. Установи вручную: https://github.com/dorssel/usbipd-win/releases и повтори." }
    if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
      Die "usbipd установлен, но не в PATH. Перезапусти PowerShell и запусти prepare.ps1 снова."
    }
  }
  # служба usbipd бывает не запущена (в т.ч. после установки/перезагрузки)
  $svc = Get-Service usbipd -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -ne "Running") {
    Info "Запускаю службу usbipd..."
    try { Start-Service usbipd } catch { Warn "Не смог запустить службу usbipd: $_" }
    Start-Sleep -Seconds 1
    $svc = Get-Service usbipd -ErrorAction SilentlyContinue
  }
  # Свежеустановленный usbipd не работает до перезагрузки ("The service is currently not
  # running; a reboot should fix that"). Без этой проверки скрипт молотит 5 бесполезных
  # ретраев attach и падает по таймауту с невнятной ошибкой. Проверено на Win11 15.07.2026.
  if (-not $svc -or $svc.Status -ne "Running") {
    Write-Host ""
    Warn "Служба usbipd установлена, но не запущена - так бывает сразу после её установки."
    Write-Host "    ПЕРЕЗАГРУЗИ компьютер и запусти prepare.ps1 снова." -ForegroundColor Cyan
    Die "Нужна перезагрузка после установки usbipd."
  }
}

$script:UsbipBusid = $null
$script:UsbipProc  = $null

# VID:PID выбранной флешки через PnP-дерево (DiskDrive -> родитель USB\VID_..&PID_..)
function Get-DiskUsbId($disk) {
  try {
    $dd = Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Where-Object { $_.Index -eq $disk.Number }
    if (-not $dd) { return $null }
    $pnp = $dd.PNPDeviceID
    # поднимаемся к родителю (обычно USB\VID_xxxx&PID_xxxx\...)
    $parent = (Get-PnpDeviceProperty -InstanceId $pnp -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data
    if ($parent -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
      return ("{0}:{1}" -f $matches[1],$matches[2]).ToLower()
    }
  } catch { }
  return $null
}

# строки 'usbipd list' без падения на stderr-инфо
function Get-UsbipdListLines {
  $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  try { return (& usbipd.exe list 2>&1 | ForEach-Object { "$_" }) }
  finally { $ErrorActionPreference = $old }
}
function Attach-Usbipd($disk) {
  Ensure-Usbipd

  # 1) пробуем определить BUSID автоматически по VID:PID выбранной флешки
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
    elseif ($hits.Count -gt 1) { Warn "Несколько USB-устройств с ID $want — выбери BUSID вручную." }
  }

  # 2) fallback — показать список и спросить
  if (-not $busid) {
    Info "Не удалось определить BUSID автоматически. Найди свою флешку в списке (столбец BUSID):"
    $lines | ForEach-Object { Write-Host $_ }
    $busid = Read-Host "Введи BUSID флешки (напр. 11-4)"
    if ($busid -notmatch '^\d+-\d+$') { Die "BUSID '$busid' не похож на правильный (формат N-N)." }
  }
  $script:UsbipBusid = $busid

  Info "modprobe usb-storage/uas + держу WSL живым..."
  Wsl "modprobe usb-storage; modprobe uas; echo ok" | Out-Null

  Invoke-Usbipd bind --busid $busid

  # Однократный attach с повторами (без вечного --auto-attach: тот на некоторых
  # контроллерах зацикливается, дёргает флешку и плодит окна автозапуска).
  # Первая попытка часто падает 'error state' — вторая/третья проходят.
  Info "Прицепляю флешку к WSL (attach с повторами)..."
  $attached = $false
  for ($a = 1; $a -le 5; $a++) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $out = (& usbipd.exe attach --wsl --busid $busid 2>&1 | ForEach-Object { "$_" })
    $ErrorActionPreference = $old
    if ($out -match 'error|failed|state') {
      Warn "Попытка $a не удалась, повтор через 3 c..."
      Start-Sleep -Seconds 3
    } else {
      $attached = $true; break
    }
  }
  if (-not $attached) {
    # последняя проверка: вдруг всё же прицепилось, несмотря на текст
    Start-Sleep -Seconds 2
  }

  # ждём появления блочного устройства в WSL (до ~40 c)
  Info "Жду, пока ядро создаст блочное устройство..."
  $found = $false
  for ($t=0; $t -lt 20; $t++) {
    Start-Sleep -Seconds 2
    $has = (Wsl "lsblk -dpno NAME,SIZE,TYPE,MODEL | grep -i disk | grep -iv 'Virtual Disk'") 2>$null
    if ($has -match "sd") { $found = $true; break }
  }
  if (-not $found) { Die "Флешка не появилась в WSL за ~40 c. Передёрни флешку/USB-порт и повтори." }
  Ok "Флешка в WSL."
  return $true
}

function Detach-Usbipd {
  if ($script:UsbipProc -and -not $script:UsbipProc.HasExited) {
    Stop-Process -Id $script:UsbipProc.Id -Force -ErrorAction SilentlyContinue
  }
  # kill any leftover usbipd auto-attach processes
  Get-Process usbipd -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID } | Stop-Process -Force -ErrorAction SilentlyContinue
  if ($script:UsbipBusid) {
    # тихо: устройство к этому моменту может быть уже отвязано auto-attach'ем
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
      & usbipd.exe detach --busid $script:UsbipBusid 2>&1 | Out-Null
      & usbipd.exe unbind --busid $script:UsbipBusid 2>&1 | Out-Null
    } finally { $ErrorActionPreference = $old }
  }
}

# ---------------------------------------------------------------- 7. disk name in WSL
function Find-WslDisk([double]$sizeBytes) {
  # Диски самой виртуалки WSL подписаны MODEL='Virtual Disk'. Настоящая флешка
  # (проброшенная через usbipd/mount) имеет реальную модель и совпадающий размер.
  # usbipd/auto-attach иногда создаёт устройство с задержкой — поэтому ждём с ретраями.
  $targetGB = [math]::Round($sizeBytes/1GB,1)
  $cand = @()

  for ($try = 0; $try -lt 15; $try++) {
    $raw = (Wsl "lsblk -dbpno NAME,SIZE,TYPE,MODEL") 2>$null
    $cand = @()
    foreach ($ln in ($raw -split "`n")) {
      $t = $ln.Trim()
      if (-not $t) { continue }
      if ($t -match '^(\S+)\s+(\d+)\s+(\S+)\s*(.*)$') {
        $name=$matches[1]; $bytes=[double]$matches[2]; $type=$matches[3]; $model=$matches[4].Trim()
        if ($type -ne "disk") { continue }
        if ($model -match 'Virtual Disk') { continue }   # диск самой WSL — пропускаем
        $cand += [pscustomobject]@{ Name=$name; GB=[math]::Round($bytes/1GB,1); Model=$model; Bytes=$bytes }
      }
    }
    if ($cand.Count -ge 1) { break }
    Start-Sleep -Seconds 2   # ещё не видно — ждём (устройство/auto-attach «устаканивается»)
  }

  if ($cand.Count -eq 0) {
    Die "Не нашёл флешку в WSL за ~30 c (все диски — Virtual Disk). Возможно, auto-attach колотит устройство: передёрни флешку и повтори."
  }

  if ($cand.Count -eq 1) {
    $pick = $cand[0]
  } else {
    $pick = $cand | Sort-Object { [math]::Abs($_.Bytes - $sizeBytes) } | Select-Object -First 1
    Warn "Кандидатов несколько, выбрал ближайший по размеру: $($pick.Name) ($($pick.GB)GB, $($pick.Model))"
  }

  $diff = [math]::Abs($pick.Bytes - $sizeBytes) / $sizeBytes
  if ($diff -gt 0.15) {
    Warn "Размер найденного диска $($pick.Name) ($($pick.GB)GB) заметно отличается от выбранного (~${targetGB}GB)."
    $ok = Read-Host "Это точно твоя флешка $($pick.Name)? (y/n)"
    if ($ok -notmatch '^[yY]') { Die "Отмена — устройство не подтверждено." }
  }
  return $pick.Name
}

# ---------------------------------------------------------------- MAIN
try {
  Ensure-Wsl
  Start-WslKeepAlive
  Ensure-WslNet
  Deliver-Script
  $arch = Choose-Arch
  $disk = Choose-UsbDisk

  $useMount = $false
  if ($IsWin11) { $useMount = Attach-Win11 $disk.Number }
  if (-not $useMount) { Attach-Usbipd $disk | Out-Null }

  $dev = Find-WslDisk $disk.Size
  Ok "Целевое устройство в WSL: $dev"

  # env-строка для DRY_RUN (подставляется в bash-команду ниже)
  $DR = if ($DryRun) { "1" } else { "0" }
  if ($DryRun) { Warn "DRY-RUN: на диск не будет записано ничего." }

  Info "Запускаю разметку (prepare-linux.sh)..."
  Write-Host ("-"*70)
  wsl.exe -d $Distro -u root -- bash -c "cd /root && DRY_RUN=$DR ARCH=$arch ASSUME_YES=1 bash prepare-linux.sh $dev"
  $rc = $LASTEXITCODE
  Write-Host ("-"*70)
  if ($rc -ne 0) { Die "prepare-linux.sh завершился с ошибкой (код $rc). Флешку не извлекаю." }

  # При dry-run итог печатает сам prepare-linux.sh (диск не тронут) - не дублируем
  # и НЕ зовём нести флешку в роутер: она не подготовлена.
  if (-not $DryRun) {
    Ok "Готово! Флешка подготовлена."
    Write-Host ""
    Write-Host "Дальше - на роутере:" -ForegroundColor Cyan
    Write-Host "  1. Вставь флешку в Keenetic."
    Write-Host "  2. Веб-интерфейс -> Общие настройки -> включи OPKG и Ext-файловую систему."
    Write-Host "  3. Страница OPKG -> выбери накопитель 'OPKG' -> Сохранить."
  }
}
finally {
  # return the flash drive to the system correctly
  if ($useMount) {
    try { wsl.exe --unmount "\\.\PHYSICALDRIVE$($disk.Number)" 2>$null } catch {}
  } else {
    Detach-Usbipd
  }
  Stop-WslKeepAlive
}

Write-Host ""
Read-Host "Готово. Нажми Enter для выхода"
