#!/usr/bin/env bash
#
# backup.sh — умный бэкап/восстановление USB-флешки Keenetic (Entware/XKeen)
# Платформа: macOS. Копирует только ЗАНЯТЫЕ блоки ext4 (через e2image) —
# образ маленький, снятие быстрое (не читает пустоту и мусор).
#
# Режимы:
#   backup.sh backup            — снять образ флешки в файл (.kbak = tar.gz)
#   backup.sh restore <файл>    — развернуть образ на флешку (СТИРАЕТ её)
#   backup.sh                   — спросит режим интерактивно
#
# Что внутри образа:
#   mbr.bin    — таблица разделов (первый 1 МБ)
#   opkg.e2img — ext4-раздел через e2image (только занятые блоки)
#   meta.txt   — метаданные (размеры, метки)
# Swap не бэкапится (временные данные) — при restore создаётся заново (mkswap -L SWAP).
#
# ВНИМАНИЕ: первый черновик, обкатывать на реальной флешке.
#
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
IGNORE_BREW="${IGNORE_BREW:-0}"
SWAP_SIZE_MB=1024
EXT4_LABEL="OPKG"
WORKDIR="$(mktemp -d)"
BUNDLE_DIR="$WORKDIR/bin"
trap 'rm -rf "$WORKDIR"' EXIT

# --- Хостинг бинарников (тот же бандл, что у prepare.sh — теперь с e2image) ---
E2FS_OWNER_REPO="lastik9/keenetic-entware"
E2FS_RELEASE_TAG="e2fsprogs-v1.47.4-macos"
E2FS_BUNDLE_NAME="e2fsprogs-macos-universal.tar.gz"
E2FS_BUNDLE_URL="https://github.com/${E2FS_OWNER_REPO}/releases/download/${E2FS_RELEASE_TAG}/${E2FS_BUNDLE_NAME}"
E2FS_BUNDLE_SHA256="ef45e9e1f11a225ecef635cec8099cf666d2bec101b72f272e22c85c3fb86e9f"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
info()  { printf "%s[i]%s %s\n" "$c_cyn" "$c_rst" "$*"; }
ok()    { printf "%s[v]%s %s\n" "$c_grn" "$c_rst" "$*"; }
warn()  { printf "%s[!]%s %s\n" "$c_yel" "$c_rst" "$*"; }
err()   { printf "%s[x]%s %s\n" "$c_red" "$c_rst" "$*" >&2; }
die()   { err "$*"; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "Этот скрипт только для macOS."
[ -e /dev/tty ] || die "Нет доступа к терминалу (/dev/tty)."

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "   %s(dry-run)%s %s\n" "$c_yel" "$c_rst" "$*"
  else
    eval "$@"
  fi
}

# ----------------------------------------------------------------------------
# Поиск/доставка e2image + e2fsck (нужны для умного образа)
# ----------------------------------------------------------------------------
find_tool() {
  local name="$1" p
  if [[ "$IGNORE_BREW" != "1" ]]; then
    for p in "/opt/homebrew/opt/e2fsprogs/sbin/$name" "/usr/local/opt/e2fsprogs/sbin/$name"; do
      [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
  fi
  [[ -x "$BUNDLE_DIR/$name" ]] && { echo "$BUNDLE_DIR/$name"; return 0; }
  return 1
}

fetch_bundle() {
  info "Скачиваю бинарники e2fsprogs..."
  mkdir -p "$BUNDLE_DIR"
  curl -fL --retry 3 -o "$WORKDIR/$E2FS_BUNDLE_NAME" "$E2FS_BUNDLE_URL" \
    || die "Не удалось скачать бинарники."
  if [[ -n "$E2FS_BUNDLE_SHA256" ]]; then
    echo "${E2FS_BUNDLE_SHA256}  $WORKDIR/$E2FS_BUNDLE_NAME" | shasum -a 256 -c - \
      || die "Контрольная сумма не совпала."
  fi
  tar -xzf "$WORKDIR/$E2FS_BUNDLE_NAME" -C "$BUNDLE_DIR"
  xattr -dr com.apple.quarantine "$BUNDLE_DIR" 2>/dev/null || true
  local t
  for t in e2image; do
    [[ -f "$BUNDLE_DIR/$t" ]] || die "В бандле нет $t (нужна свежая версия бандла с e2image)."
    chmod +x "$BUNDLE_DIR/$t"
    codesign --force -s - "$BUNDLE_DIR/$t" 2>/dev/null || true
  done
}

E2IMAGE=""
ensure_tools() {
  E2IMAGE="$(find_tool e2image || true)"
  if [[ -z "$E2IMAGE" ]]; then
    fetch_bundle
    E2IMAGE="$(find_tool e2image || true)"
  fi
  [[ -n "$E2IMAGE" ]] || die "Не удалось подготовить e2image."
  ok "e2image: $E2IMAGE"
}

# ----------------------------------------------------------------------------
# Выбор съёмного диска
# ----------------------------------------------------------------------------
pick_disk() {
  local prompt="$1" disks=() d inf name size i choice
  while IFS= read -r line; do
    [[ -n "$line" ]] && disks+=("$line")
  done < <(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk/ {print $1}')
  [[ ${#disks[@]} -gt 0 ]] || die "Съёмные накопители не найдены. Вставь флешку."
  printf "%s%s%s\n" "$c_cyn" "$prompt" "$c_rst" >&2
  i=1
  for d in "${disks[@]}"; do
    inf="$(diskutil info "$d" 2>/dev/null)"
    name="$(printf '%s\n' "$inf" | awk -F: '/Device \/ Media Name/{gsub(/^ +/,"",$2); print $2; exit}')"
    size="$(printf '%s\n' "$inf" | awk -F: '/Disk Size/{gsub(/^ +/,"",$2); split($2,a,"("); gsub(/ +$/,"",a[1]); print a[1]; exit}')"
    printf "  %s%d)%s %s — %s, %s\n" "$c_grn" "$i" "$c_rst" "$d" "$name" "$size" >&2
    i=$((i+1))
  done
  read -rp "Номер накопителя (или q): " choice < /dev/tty
  [[ "$choice" == "q" ]] && exit 0
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#disks[@]} )) || die "Некорректный выбор."
  echo "${disks[$((choice-1))]}"
}

disk_size_bytes() { diskutil info "$1" 2>/dev/null | awk -F'[()]' '/Disk Size/{print $2; exit}' | awk '{print $1}'; }

# ----------------------------------------------------------------------------
# BACKUP
# ----------------------------------------------------------------------------
do_backup() {
  ensure_tools
  local DISK RAW EXT4_RAW OUT STAGE
  DISK="$(pick_disk 'Выбери флешку для СНЯТИЯ образа:')"
  RAW="${DISK/\/dev\/disk/\/dev\/rdisk}"
  EXT4_RAW="${RAW}s2"   # ext4 — второй раздел (наша разметка: s1=swap, s2=ext4)

  local desc; desc="$(diskutil info "$DISK" | awk -F: '/Device \/ Media Name|Disk Size/ {gsub(/^ +/,"",$2); print $2}' | paste -sd', ' -)"
  info "Источник: $DISK ($desc)"

  OUT="keenetic-backup-$(date +%Y%m%d-%H%M).kbak"
  STAGE="$WORKDIR/stage"; mkdir -p "$STAGE"

  info "Размонтирую диск..."
  run "diskutil unmountDisk force $DISK"

  # 1. Таблица разделов (первый 1 МБ)
  info "Сохраняю таблицу разделов..."
  run "sudo dd if=$RAW of=$STAGE/mbr.bin bs=1m count=1 2>/dev/null"

  # 2. ext4 через e2image -ra (raw-образ ВКЛЮЧАЯ данные файлов, пустое пропускается)
  info "Снимаю умный образ ext4 (занятые блоки + данные)..."
  run "sudo $E2IMAGE -ra $EXT4_RAW $STAGE/opkg.e2img"

  # sudo создал файлы владельцем root — возвращаем их текущему пользователю,
  # иначе tar (под обычным пользователем) не сможет их прочитать.
  if [[ "$DRY_RUN" != "1" ]]; then
    sudo chown "$(id -u):$(id -g)" "$STAGE/mbr.bin" "$STAGE/opkg.e2img" 2>/dev/null || true
  fi

  # 3. Метаданные
  if [[ "$DRY_RUN" != "1" ]]; then
    {
      echo "source_disk_bytes=$(disk_size_bytes "$DISK")"
      echo "ext4_label=OPKG"
      echo "swap_label=SWAP"
      echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$STAGE/meta.txt"
    # упаковка
    tar -czf "$OUT" -C "$STAGE" mbr.bin opkg.e2img meta.txt
    ok "Образ снят: $OUT ($(du -h "$OUT" | cut -f1))"
  else
    warn "(dry-run) tar -czf $OUT mbr.bin opkg.e2img meta.txt"
  fi

  run "diskutil mountDisk $DISK" || true
  echo
  ok "Готово. Файл $OUT — из него можно восстановить флешку."
}

# ----------------------------------------------------------------------------
# RESTORE
# ----------------------------------------------------------------------------
do_restore() {
  ensure_tools
  local IMG="${1:-}"
  [[ -n "$IMG" ]] || read -rp "Путь к файлу образа (.kbak): " IMG < /dev/tty
  [[ -f "$IMG" ]] || die "Файл образа не найден: $IMG"

  # распаковка
  local STAGE="$WORKDIR/restore"; mkdir -p "$STAGE"
  tar -xzf "$IMG" -C "$STAGE" || die "Не удалось распаковать образ."
  [[ -f "$STAGE/mbr.bin" && -f "$STAGE/opkg.e2img" ]] || die "Образ повреждён (нет mbr.bin/opkg.e2img)."

  local src_bytes; src_bytes="$(awk -F= '/source_disk_bytes/{print $2}' "$STAGE/meta.txt" 2>/dev/null)"

  local DISK RAW EXT4_RAW SWAP_DEV
  DISK="$(pick_disk 'Выбери флешку для ЗАПИСИ образа (будет СТЁРТА):')"
  RAW="${DISK/\/dev\/disk/\/dev\/rdisk}"
  EXT4_RAW="${RAW}s2"

  # проверка вместимости
  local dst_bytes; dst_bytes="$(disk_size_bytes "$DISK")"
  if [[ -n "$src_bytes" && -n "$dst_bytes" && "$src_bytes" -gt "$dst_bytes" ]]; then
    die "Образ снят с флешки $src_bytes Б, целевая — $dst_bytes Б. Нужна флешка не меньше исходной."
  fi

  local desc; desc="$(diskutil info "$DISK" | awk -F: '/Device \/ Media Name|Disk Size/ {gsub(/^ +/,"",$2); print $2}' | paste -sd', ' -)"
  echo
  warn "Диск $DISK ($desc) будет ПОЛНОСТЬЮ СТЁРТ."
  local confirm; read -rp "Для подтверждения введи ровно '$DISK': " confirm < /dev/tty
  [[ "$confirm" == "$DISK" ]] || die "Подтверждение не совпало. Отмена."

  info "Размонтирую диск..."
  run "diskutil unmountDisk force $DISK"

  # 1. Пересоздать разметку через diskutil (надёжно создаёт ноды разделов,
  #    в отличие от сырой записи MBR через dd, которую macOS не перечитывает).
  #    Раскладка стандартная: swap 1 ГБ + ext4 остаток — как в prepare.sh.
  info "Создаю разметку (swap 1 ГБ + ext4 остаток)..."
  run "diskutil partitionDisk $DISK MBR \
    \"MS-DOS FAT32\" SWAP 1024M \
    \"MS-DOS FAT32\" OPKG R"

  info "Размонтирую перед разворачиванием..."
  run "diskutil unmountDisk force $DISK"

  # 2. Развернуть ext4: e2image пишет в ФАЙЛ (в устройство macOS напрямую не умеет —
  #    даёт "block -1"), затем dd conv=sparse быстро льёт файл на раздел, пропуская нули.
  info "Разворачиваю ext4 из образа..."
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "(dry-run) e2image -ra opkg.e2img -> файл, затем dd conv=sparse на $EXT4_RAW"
  else
    # размер целевого раздела в байтах (файл делаем РОВНО под него, иначе I/O error на хвосте)
    local part_bytes
    part_bytes="$(diskutil info "${DISK}s2" 2>/dev/null | awk -F'[()]' '/Disk Size|Partition Size/{print $2; exit}' | awk '{print $1}')"
    [[ -n "$part_bytes" ]] || die "Не удалось определить размер раздела ${DISK}s2."
    local tmpimg="$WORKDIR/restore-fs.img"
    truncate -s "$part_bytes" "$tmpimg" 2>/dev/null || mkfile -n "${part_bytes}" "$tmpimg" 2>/dev/null || \
      dd if=/dev/zero of="$tmpimg" bs=1 count=0 seek="$part_bytes" 2>/dev/null
    info "  e2image -ra в файл..."
    sudo "$E2IMAGE" -ra "$STAGE/opkg.e2img" "$tmpimg" || die "e2image -ra не смог развернуть образ в файл."
    sudo chown "$(id -u):$(id -g)" "$tmpimg" 2>/dev/null || true
    info "  заливаю на раздел (dd conv=sparse, только данные)..."
    run "diskutil unmountDisk force $DISK"
    sudo dd if="$tmpimg" of="$EXT4_RAW" bs=4m conv=sparse 2>/dev/null || true
    ok "ext4 развёрнут на $EXT4_RAW."
  fi

  # 3. Типы разделов (0x82 swap, 0x83 Linux) — как в prepare.sh
  info "Выставляю типы разделов..."
  if [[ "$DRY_RUN" != "1" ]]; then
    sudo fdisk -e "$DISK" <<'FDISK' 2>/dev/null || warn "fdisk: типы можно оставить."
setpid 1
82
setpid 2
83
write
quit
FDISK
  else
    warn "(dry-run) sudo fdisk -e $DISK: типы 82/83"
  fi

  # 4. Почистить swap-раздел (FAT-хвост); swap-сигнатуру сделает роутер
  SWAP_DEV="${RAW}s1"
  info "Чищу swap-раздел..."
  run "sudo dd if=/dev/zero of=$SWAP_DEV bs=1m count=8 2>/dev/null"

  run "diskutil eject $DISK" || true
  echo
  ok "Готово. Флешку можно вставить в роутер."
  info "Swap активируется на роутере (router-setup.sh сделает mkswap -L SWAP)."
}

# ----------------------------------------------------------------------------
# Точка входа
# ----------------------------------------------------------------------------
MODE="${1:-}"
if [[ -z "$MODE" ]]; then
  printf "%sЧто сделать?%s\n" "$c_cyn" "$c_rst"
  echo "  1) backup  — снять образ флешки"
  echo "  2) restore — записать образ на флешку"
  read -rp "Номер (1/2): " m < /dev/tty
  case "$m" in 1) MODE="backup" ;; 2) MODE="restore" ;; *) die "Некорректный выбор." ;; esac
fi

case "$MODE" in
  backup)  do_backup ;;
  restore) shift || true; do_restore "${1:-}" ;;
  *) die "Использование: backup.sh {backup|restore <файл>}" ;;
esac
