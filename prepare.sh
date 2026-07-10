#!/usr/bin/env bash
#
# keenetic-entware-flash — подготовка USB-флешки под Entware для роутеров Keenetic
# Платформа: macOS (Intel + Apple Silicon), совместимость с bash 3.2 (голый мак)
#
# Доставка e2fsprogs (mke2fs/debugfs):
#   - по умолчанию: если стоит Homebrew с e2fsprogs — берём оттуда;
#     иначе качаем universal-бинарники из GitHub Releases (ноль установок).
#   - IGNORE_BREW=1: игнорировать Homebrew и всегда идти по пути «голого мака»
#     (качать бинарники). Удобно, чтобы протестировать оба сценария, не трогая brew.
#
# Тест:
#   DRY_RUN=1 bash prepare.sh                # обычный путь (brew, если есть)
#   IGNORE_BREW=1 DRY_RUN=1 bash prepare.sh  # путь «голого мака» (brew будто нет)
#
# DRY_RUN=1 защищает ДИСК от записи (разметка/формат/eject не выполняются).
# Скачивание бинарников/installer'а при этом происходит — это безопасно.
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Настройки
# ----------------------------------------------------------------------------
SWAP_SIZE_MB=1024
EXT4_LABEL="OPKG"
DRY_RUN="${DRY_RUN:-0}"
IGNORE_BREW="${IGNORE_BREW:-0}"
WORKDIR="$(mktemp -d)"
BUNDLE_DIR="$WORKDIR/bin"
trap 'rm -rf "$WORKDIR"' EXIT

# --- Хостинг universal-бинарников e2fsprogs (заполнить после публикации Release) ---
# Тарбол должен содержать исполняемые mke2fs и debugfs (universal arm64+x86_64),
# со статически влинкованными внутренними либами e2fsprogs (зависимость только
# от /usr/lib/libSystem, который есть на любом маке).
E2FS_OWNER_REPO="lastik9/keenetic-entware"             # владелец/репозиторий на GitHub
E2FS_RELEASE_TAG="e2fsprogs-v1.47.4-macos"             # тег релиза с бинарниками
E2FS_BUNDLE_NAME="e2fsprogs-macos-universal.tar.gz"
E2FS_BUNDLE_URL="https://github.com/${E2FS_OWNER_REPO}/releases/download/${E2FS_RELEASE_TAG}/${E2FS_BUNDLE_NAME}"
E2FS_BUNDLE_SHA256="f5364b62a415ba34f9da8708048da468786fe137aa8d39d035b94de24beee833"   # sha256 тарбола для проверки целостности

# --- URL bootstrap-installer'ов Entware (сверять с bin.entware.net) ---
URL_MIPSEL="https://bin.entware.net/mipselsf-k3.4/installer/mipsel-installer.tar.gz"
URL_MIPS="https://bin.entware.net/mipssf-k3.4/installer/mips-installer.tar.gz"
URL_AARCH64="https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz"

# ----------------------------------------------------------------------------
# Вывод
# ----------------------------------------------------------------------------
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
info()  { printf "%s[i]%s %s\n" "$c_cyn" "$c_rst" "$*"; }
ok()    { printf "%s[v]%s %s\n" "$c_grn" "$c_rst" "$*"; }
warn()  { printf "%s[!]%s %s\n" "$c_yel" "$c_rst" "$*"; }
err()   { printf "%s[x]%s %s\n" "$c_red" "$c_rst" "$*" >&2; }
die()   { err "$*"; exit 1; }

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "   %s(dry-run)%s %s\n" "$c_yel" "$c_rst" "$*"
  else
    eval "$@"
  fi
}

# ----------------------------------------------------------------------------
# 0. Окружение
# ----------------------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "Этот скрипт только для macOS."

# Интерактивный ввод (выбор диска/арки) читается с /dev/tty — это позволяет
# запускать скрипт и через `curl | bash`, и через `bash <(curl ...)`.
[ -e /dev/tty ] || die "Нет доступа к терминалу (/dev/tty). Запусти скрипт в обычном Терминале."

# Поиск бинарника: brew-keg (если не IGNORE_BREW) -> скачанный bundle
find_tool() {
  local name="$1" p
  if [[ "$IGNORE_BREW" != "1" ]]; then
    for p in \
      "/opt/homebrew/opt/e2fsprogs/sbin/$name" \
      "/usr/local/opt/e2fsprogs/sbin/$name" ; do
      [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
  fi
  [[ -x "$BUNDLE_DIR/$name" ]] && { echo "$BUNDLE_DIR/$name"; return 0; }
  return 1
}

# Скачать + подготовить universal-бинарники (путь «голого мака»)
fetch_bundle() {
  info "Скачиваю universal-бинарники e2fsprogs..."
  mkdir -p "$BUNDLE_DIR"
  # curl-загрузка НЕ ставит флаг карантина (в отличие от скачивания браузером)
  curl -fL --retry 3 -o "$WORKDIR/$E2FS_BUNDLE_NAME" "$E2FS_BUNDLE_URL" \
    || die "Не удалось скачать бинарники ($E2FS_BUNDLE_URL). Проверь тег релиза/интернет."
  [[ -s "$WORKDIR/$E2FS_BUNDLE_NAME" ]] || die "Скачанный архив пустой."

  if [[ -n "$E2FS_BUNDLE_SHA256" ]]; then
    info "Проверяю контрольную сумму..."
    echo "${E2FS_BUNDLE_SHA256}  $WORKDIR/$E2FS_BUNDLE_NAME" | shasum -a 256 -c - \
      || die "Контрольная сумма не совпала — файл повреждён или подменён."
  fi

  tar -xzf "$WORKDIR/$E2FS_BUNDLE_NAME" -C "$BUNDLE_DIR" \
    || die "Не удалось распаковать бинарники."

  # На всякий случай снимаем карантин и делаем ad-hoc подпись (нужна на Apple Silicon)
  xattr -dr com.apple.quarantine "$BUNDLE_DIR" 2>/dev/null || true
  local t
  for t in mke2fs debugfs; do
    [[ -f "$BUNDLE_DIR/$t" ]] || die "В архиве нет $t."
    chmod +x "$BUNDLE_DIR/$t"
    codesign --force -s - "$BUNDLE_DIR/$t" 2>/dev/null || \
      warn "codesign для $t не прошёл (возможно, на Intel это не требуется)."
  done
  ok "Бинарники готовы: $BUNDLE_DIR"
}

# Гарантируем наличие mke2fs/debugfs
MKE2FS=""; DEBUGFS=""
ensure_e2fsprogs() {
  MKE2FS="$(find_tool mke2fs || true)"
  DEBUGFS="$(find_tool debugfs || true)"
  if [[ -n "$MKE2FS" && -n "$DEBUGFS" ]]; then
    [[ "$IGNORE_BREW" == "1" ]] && info "IGNORE_BREW=1 — Homebrew игнорируется."
    return 0
  fi
  # Не нашли локально — качаем bundle
  fetch_bundle
  MKE2FS="$(find_tool mke2fs || true)"
  DEBUGFS="$(find_tool debugfs || true)"
  [[ -n "$MKE2FS" && -n "$DEBUGFS" ]] || die "Не удалось подготовить e2fsprogs."
}

ensure_e2fsprogs
ok "mke2fs:  $MKE2FS"
ok "debugfs: $DEBUGFS"

# ----------------------------------------------------------------------------
# 1. Выбор диска — ТОЛЬКО съёмные (bash 3.2 совместимо, без mapfile)
# ----------------------------------------------------------------------------
info "Ищу съёмные USB-накопители..."
EXT_DISKS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && EXT_DISKS+=("$line")
done < <(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk/ {print $1}')

[[ ${#EXT_DISKS[@]} -gt 0 ]] || die "Съёмные накопители не найдены. Вставь флешку и повтори."

echo
printf "%sНайденные съёмные накопители:%s\n" "$c_cyn" "$c_rst"
i=1
for d in "${EXT_DISKS[@]}"; do
  inf="$(diskutil info "$d" 2>/dev/null)"
  name="$(printf '%s\n' "$inf" | awk -F: '/Device \/ Media Name/{gsub(/^ +/,"",$2); print $2; exit}')"
  size="$(printf '%s\n' "$inf" | awk -F: '/Disk Size/{gsub(/^ +/,"",$2); split($2,a,"("); gsub(/ +$/,"",a[1]); print a[1]; exit}')"
  printf "  %s%d)%s %s — %s, %s\n" "$c_grn" "$i" "$c_rst" "$d" "$name" "$size"
  i=$((i+1))
done
echo

read -rp "Номер накопителя для подготовки (или q для выхода): " choice < /dev/tty
[[ "$choice" == "q" ]] && exit 0
[[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#EXT_DISKS[@]} )) \
  || die "Некорректный выбор."
DISK="${EXT_DISKS[$((choice-1))]}"

_inf="$(diskutil info "$DISK" 2>/dev/null)"
_name="$(printf '%s\n' "$_inf" | awk -F: '/Device \/ Media Name/{gsub(/^ +/,"",$2); print $2; exit}')"
_size="$(printf '%s\n' "$_inf" | awk -F: '/Disk Size/{gsub(/^ +/,"",$2); split($2,a,"("); gsub(/ +$/,"",a[1]); print a[1]; exit}')"
DISK_DESC="$_name, $_size"
echo
warn "Диск $DISK ($DISK_DESC) будет ПОЛНОСТЬЮ СТЁРТ."
read -rp "Для подтверждения введи ровно '$DISK': " confirm < /dev/tty
[[ "$confirm" == "$DISK" ]] || die "Подтверждение не совпало. Отмена."

# ----------------------------------------------------------------------------
# 2. Меню выбора архитектуры
# ----------------------------------------------------------------------------
echo
printf "%sВыбери архитектуру процессора роутера:%s\n" "$c_cyn" "$c_rst"
cat <<'ARCH'
  1) mipsel  — Giga (KN-1010/1011), Ultra (KN-1810), Extra (KN-1710/1711/1713),
               Omni (KN-1410), Viva (KN-1910/1912/1913), Giant (KN-2610),
               Hero 4G (KN-2310/2311), Hopper (KN-3810), 4G (KN-1212), + Zyxel Keenetic II/III и др.
  2) mips    — Ultra SE (KN-2510), Giga SE (KN-2410), DSL (KN-2010), Duo (KN-2110),
               Skipper DSL (KN-2112), Hopper DSL (KN-3610), + Zyxel Keenetic DSL/LTE/VOX
  3) aarch64 — Peak (KN-2710), Ultra (KN-1811/NC-1812), Giga (KN-1012),
               Hopper (KN-3811), Hopper SE (KN-3812)
ARCH
read -rp "Номер (1/2/3): " arch_choice < /dev/tty
case "$arch_choice" in
  1) ARCH="mipsel";  INSTALLER_URL="$URL_MIPSEL"  ;;
  2) ARCH="mips";    INSTALLER_URL="$URL_MIPS"    ;;
  3) ARCH="aarch64"; INSTALLER_URL="$URL_AARCH64" ;;
  *) die "Некорректный выбор архитектуры." ;;
esac
INSTALLER_NAME="${ARCH}-installer.tar.gz"
ok "Архитектура: $ARCH"

# ----------------------------------------------------------------------------
# 3. Скачиваем installer заранее (до разметки — чтобы не стирать зря)
# ----------------------------------------------------------------------------
info "Скачиваю $INSTALLER_NAME ..."
curl -fL --retry 3 -o "$WORKDIR/$INSTALLER_NAME" "$INSTALLER_URL" \
  || die "Не удалось скачать installer. Проверь URL/интернет."
[[ -s "$WORKDIR/$INSTALLER_NAME" ]] || die "Скачанный installer пустой."
ok "Installer готов ($(du -h "$WORKDIR/$INSTALLER_NAME" | cut -f1))"

# ----------------------------------------------------------------------------
# 4. Права администратора (нужны для прямого доступа к устройству)
# ----------------------------------------------------------------------------
# diskutil работает через привилегированный демон и sudo не требует,
# а fdisk/mke2fs/debugfs пишут в устройство напрямую -> нужен root.
if [[ "$DRY_RUN" != "1" ]]; then
  info "Для записи на устройство нужны права администратора (введи пароль)."
  sudo -v || die "Не удалось получить права администратора."
fi

# ----------------------------------------------------------------------------
# 5. Разметка: MBR, swap (1 ГБ), ext4 (остаток)
# ----------------------------------------------------------------------------
info "Размонтирую диск..."
run "diskutil unmountDisk force $DISK"

info "Создаю разметку MBR (swap ${SWAP_SIZE_MB}M + ext4 остаток)..."
run "diskutil partitionDisk $DISK MBR \
  \"MS-DOS FAT32\" SWAP ${SWAP_SIZE_MB}M \
  \"MS-DOS FAT32\" ${EXT4_LABEL} R"

SWAP_SLICE="${DISK}s1"
EXT4_SLICE="${DISK}s2"
SWAP_RAW="${SWAP_SLICE/\/dev\/disk/\/dev\/rdisk}"
EXT4_RAW="${EXT4_SLICE/\/dev\/disk/\/dev\/rdisk}"

# ----------------------------------------------------------------------------
# 6. Форматируем ext4 (на свежих нодах, сразу после разметки)
# ----------------------------------------------------------------------------
info "Размонтирую перед mke2fs..."
run "diskutil unmountDisk force $DISK"

info "Очищаю FAT-сигнатуру на swap-разделе (иначе роутер видит его как VFAT)..."
run "sudo dd if=/dev/zero of=$SWAP_RAW bs=1m count=8 2>/dev/null"

info "Форматирую $EXT4_SLICE в ext4 (метка $EXT4_LABEL)..."
run "sudo $MKE2FS -F -t ext4 -L $EXT4_LABEL -O ^64bit,^metadata_csum $EXT4_RAW"
ok "ext4 создан."

# ----------------------------------------------------------------------------
# 7. install/<arch>-installer.tar.gz через debugfs (без монтирования)
# ----------------------------------------------------------------------------
info "Записываю $INSTALLER_NAME в /install на ext4 (debugfs)..."
if [[ "$DRY_RUN" == "1" ]]; then
  warn "(dry-run) sudo debugfs -w: mkdir /install; write $INSTALLER_NAME"
else
  sudo "$DEBUGFS" -w "$EXT4_RAW" 2>/dev/null <<EOF
mkdir /install
cd /install
write $WORKDIR/$INSTALLER_NAME $INSTALLER_NAME
quit
EOF
  ok "Installer записан в install/$INSTALLER_NAME"
fi

# ----------------------------------------------------------------------------
# 8. Типы разделов (последним шагом: 0x82 swap, 0x83 Linux)
# ----------------------------------------------------------------------------
info "Размонтирую перед правкой типов разделов..."
run "diskutil unmountDisk force $DISK"

info "Выставляю типы разделов (0x82 swap, 0x83 Linux) через fdisk..."
if [[ "$DRY_RUN" == "1" ]]; then
  warn "(dry-run) sudo fdisk -e $DISK: setpid 1->82, setpid 2->83, write"
else
  sudo fdisk -e "$DISK" <<'FDISK' || warn "fdisk вернул ошибку — типы можно оставить, ext4 роутер видит по ФС"
setpid 1
82
setpid 2
83
write
quit
FDISK
fi

# ----------------------------------------------------------------------------
# 9. Самопроверка результата (до извлечения)
# ----------------------------------------------------------------------------
if [[ "$DRY_RUN" != "1" ]]; then
  echo
  info "Проверяю результат..."
  verify_ok=1

  # ext4 + наличие install/<installer> через debugfs (используем уже имеющийся тул)
  ls_out="$(sudo "$DEBUGFS" -R "ls -l /install" "$EXT4_RAW" 2>/dev/null || true)"
  if printf '%s' "$ls_out" | grep -q "$INSTALLER_NAME"; then
    ok "ext4 читается, install/$INSTALLER_NAME на месте."
  else
    err "Не вижу install/$INSTALLER_NAME на ext4-разделе!"
    verify_ok=0
  fi

  # Типы разделов: ждём 82 (swap) и 83 (Linux)
  types="$(sudo fdisk "$DISK" 2>/dev/null | awk '/^ [12]:/{print $2}' | paste -sd',' -)"
  if [[ "$types" == "82,83" ]]; then
    ok "Типы разделов корректны: swap=0x82, ext4=0x83."
  else
    warn "Типы разделов: [$types] (ожидалось 82,83). Не критично — роутер видит ext4 по ФС."
  fi

  [[ "$verify_ok" == "1" ]] || die "Проверка не прошла — не извлекаю, разберёмся."
fi

# ----------------------------------------------------------------------------
# 10. Финал
# ----------------------------------------------------------------------------
run "diskutil eject $DISK" || true
echo
ok "Флешка готова!"
cat <<NEXT

${c_cyn}Дальнейшие шаги на роутере:${c_rst}
  1. Вставь флешку в Keenetic.
  2. Веб-интерфейс -> Общие настройки -> включи компоненты:
       «Поддержка открытых пакетов (OPKG)» и «Файловая система Ext».
  3. Страница OPKG -> выбери накопитель «${EXT4_LABEL}» -> Сохранить.
     Роутер распакует install/${INSTALLER_NAME} и докачает пакеты с bin.entware.net
     (нужен интернет на роутере).
  4. Дождись в Журнале (Диагностика) строк об успешной установке Entware.

${c_cyn}Настройка роутера (swap + подготовка под XKeen):${c_rst}
  Зайди по SSH (root / порт 222) и запусти хелпер — он сам активирует swap
  (с автозапуском) и поставит базовые пакеты. Две команды:
     opkg update && opkg install wget-ssl ca-bundle ca-certificates
     wget -qO- https://raw.githubusercontent.com/lastik9/keenetic-entware/main/router-setup.sh | sh

NEXT
