#!/usr/bin/env bash
#
# backup.sh — умный бэкап/восстановление USB-флешки Keenetic (Entware/XKeen)
# Платформа: macOS. Копирует только ЗАНЯТЫЕ блоки ext4 (через e2image) —
# образ маленький, снятие быстрое (не читает пустоту и мусор).
#
# Режимы (одна команда → меню, либо аргументом):
#   backup.sh                   — покажет меню (backup / restore / clone)
#   backup.sh backup            — снять образ флешки в файл (.kbak = tar.gz)
#   backup.sh restore [файл]    — развернуть образ на флешку (СТИРАЕТ её);
#                                 без аргумента предложит выбрать .kbak из списка
#   backup.sh clone             — снять образ с одной флешки и СРАЗУ залить
#                                 на другую (без ручного ввода имени файла)
#
# Что внутри образа:
#   mbr.bin    — таблица разделов (первый 1 МБ)
#   opkg.e2img — ext4-раздел через e2image (только занятые блоки)
#   meta.txt   — метаданные (размеры, метки)
# Swap не бэкапится (временные данные) — при restore создаётся заново (mkswap -L SWAP).
#
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
IGNORE_BREW="${IGNORE_BREW:-0}"
SWAP_SIZE_MB=1024
EXT4_LABEL="OPKG"
WORKDIR="$(mktemp -d)"
BUNDLE_DIR="$WORKDIR/bin"
LAST_BACKUP=""          # путь к последнему снятому образу (для режима clone)
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
# Поиск/доставка e2image (нужен для умного образа)
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
  [[ -n "$E2IMAGE" ]] && return 0        # уже нашли (важно для режима clone)
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
  local prompt="$1" disks=() d inf name size i choice line
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
# Выбор файла образа (.kbak) из списка — чтобы не вводить имя руками
# ----------------------------------------------------------------------------
pick_backup_file() {
  local files=() f i choice
  local search_dirs=("$PWD")
  [[ "$PWD" != "$HOME/keenetic" && -d "$HOME/keenetic" ]] && search_dirs+=("$HOME/keenetic")

  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(find "${search_dirs[@]}" -maxdepth 1 -type f -name '*.kbak' 2>/dev/null | sort)

  if [[ ${#files[@]} -eq 0 ]]; then
    warn "Файлы .kbak рядом не найдены — введи путь вручную." >&2
    read -rp "Путь к файлу образа (.kbak): " f < /dev/tty
    echo "$f"; return 0
  fi

  printf "%sВыбери файл образа для восстановления:%s\n" "$c_cyn" "$c_rst" >&2
  i=1
  for f in "${files[@]}"; do
    printf "  %s%d)%s %s  (%s, %s)\n" "$c_grn" "$i" "$c_rst" \
      "$f" \
      "$(du -h "$f" 2>/dev/null | cut -f1)" \
      "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null)" >&2
    i=$((i+1))
  done
  printf "  %sp)%s ввести путь вручную\n" "$c_grn" "$c_rst" >&2
  read -rp "Номер файла (или p / q): " choice < /dev/tty
  [[ "$choice" == "q" ]] && exit 0
  if [[ "$choice" == "p" ]]; then
    read -rp "Путь к файлу образа (.kbak): " f < /dev/tty
    echo "$f"; return 0
  fi
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#files[@]} )) || die "Некорректный выбор."
  echo "${files[$((choice-1))]}"
}

# ----------------------------------------------------------------------------
# BACKUP
#   Аргумент finish: mount (по умолчанию — вернуть диск в систему)
#                    eject (для clone — извлечь, чтобы можно было вынуть флешку)
#   По завершении путь к образу кладётся в глобальную LAST_BACKUP.
# ----------------------------------------------------------------------------
do_backup() {
  ensure_tools
  local finish="${1:-mount}"
  local DISK RAW EXT4_RAW OUT STAGE
  DISK="$(pick_disk 'Выбери флешку для СНЯТИЯ образа:')"
  RAW="${DISK/\/dev\/disk/\/dev\/rdisk}"
  EXT4_RAW="${RAW}s2"   # ext4 — второй раздел (наша разметка: s1=swap, s2=ext4)

  local desc; desc="$(diskutil info "$DISK" | awk -F: '/Device \/ Media Name|Disk Size/ {gsub(/^ +/,"",$2); print $2}' | paste -sd', ' -)"
  info "Источник: $DISK ($desc)"

  # Размер ext4-раздела источника — понадобится при restore, чтобы писать
  # файл-образ ровно под исходную ФС (быстрее), а не под целевой раздел.
  local ext4_part_bytes
  ext4_part_bytes="$(diskutil info "${DISK}s2" 2>/dev/null | awk -F'[()]' '/Disk Size|Partition Size/{print $2; exit}' | awk '{print $1}')"

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
      echo "ext4_part_bytes=${ext4_part_bytes}"
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

  # запомним абсолютный путь для режима clone
  LAST_BACKUP="$PWD/$OUT"

  if [[ "$finish" == "eject" ]]; then
    run "diskutil eject $DISK" || true
    info "Исходную флешку можно вынимать."
  else
    run "diskutil mountDisk $DISK" || true
  fi
  echo
  ok "Готово. Файл: $LAST_BACKUP"
  info "Из него можно восстановить/клонировать флешку."
}

# ----------------------------------------------------------------------------
# RESTORE  (логика разворачивания — как в проверенной версии, без изменений)
# ----------------------------------------------------------------------------
do_restore() {
  ensure_tools
  local IMG="${1:-}"
  [[ -n "$IMG" ]] || IMG="$(pick_backup_file)"
  [[ -f "$IMG" ]] || die "Файл образа не найден: $IMG"
  info "Образ: $IMG"

  # распаковка
  local STAGE="$WORKDIR/restore"; mkdir -p "$STAGE"
  tar -xzf "$IMG" -C "$STAGE" || die "Не удалось распаковать образ."
  [[ -f "$STAGE/mbr.bin" && -f "$STAGE/opkg.e2img" ]] || die "Образ повреждён (нет mbr.bin/opkg.e2img)."

  local src_bytes; src_bytes="$(awk -F= '/source_disk_bytes/{print $2}' "$STAGE/meta.txt" 2>/dev/null)"
  local src_ext4_bytes; src_ext4_bytes="$(awk -F= '/^ext4_part_bytes=/{print $2}' "$STAGE/meta.txt" 2>/dev/null)"

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
  #    даёт "block -1"), затем dd льёт файл на раздел ЦЕЛИКОМ.
  #    ВАЖНО: без conv=sparse! Иначе dd пропускает нулевые блоки, и на их месте
  #    остаётся мусор от старого форматирования -> повреждённая ФС. Пишем всё.
  info "Разворачиваю ext4 из образа..."
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "(dry-run) e2image -ra opkg.e2img -> файл(размер исходной ФС), затем dd на $EXT4_RAW"
  else
    # Размер ЦЕЛЕВОГО раздела — для проверки вместимости.
    local part_bytes
    part_bytes="$(diskutil info "${DISK}s2" 2>/dev/null | awk -F'[()]' '/Disk Size|Partition Size/{print $2; exit}' | awk '{print $1}')"
    [[ -n "$part_bytes" ]] || die "Не удалось определить размер раздела ${DISK}s2."

    # Размер файла-образа = размер ИСХОДНОЙ ext4 (из meta), а НЕ целевого раздела.
    # Пишем только реальный объём исходной ФС -> на большой флешке вдвое быстрее.
    # Хвост за границей ФС не трогаем (ФС считает себя исходного размера и туда
    # не заглядывает; растянем позже resize2fs на роутере).
    # ВАЖНО: пишем НЕПРЕРЫВНО, без conv=sparse — sparse пропускал бы нули ВНУТРИ
    # ФС и оставлял мусор -> битая ФС. Мы лишь укорачиваем запись по границе ФС.
    local img_bytes="$src_ext4_bytes"
    if [[ -z "$img_bytes" ]]; then
      warn "В образе нет размера ФС (старый .kbak) — пишу под целевой раздел (медленнее, как раньше)."
      img_bytes="$part_bytes"
    fi
    if [[ "$img_bytes" -gt "$part_bytes" ]]; then
      die "ФС образа ($img_bytes Б) больше целевого раздела ($part_bytes Б). Нужна флешка крупнее."
    fi

    local tmpimg="$WORKDIR/restore-fs.img"
    truncate -s "$img_bytes" "$tmpimg" 2>/dev/null || mkfile -n "${img_bytes}" "$tmpimg" 2>/dev/null || \
      dd if=/dev/zero of="$tmpimg" bs=1 count=0 seek="$img_bytes" 2>/dev/null
    info "  e2image -ra в файл (ФС ~$(( img_bytes / 1024 / 1024 )) МБ)..."
    sudo "$E2IMAGE" -ra "$STAGE/opkg.e2img" "$tmpimg" || die "e2image -ra не смог развернуть образ в файл."
    sudo chown "$(id -u):$(id -g)" "$tmpimg" 2>/dev/null || true
    info "  заливаю на раздел (~$(( img_bytes / 1024 / 1024 )) МБ, без sparse; на USB 2.0 не прерывай)..."
    run "diskutil unmountDisk force $DISK"
    sudo dd if="$tmpimg" of="$EXT4_RAW" bs=4m 2>/dev/null || die "dd не смог записать образ на раздел."
    ok "ext4 развёрнут на $EXT4_RAW (размер исходной ФС; на роутере растянется resize2fs)."
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
# CLONE — снять образ с одной флешки и сразу залить на другую
# ----------------------------------------------------------------------------
do_clone() {
  info "Режим КЛОН: снимем образ с исходной флешки и сразу зальём на целевую."
  echo
  do_backup eject                      # снимает образ, извлекает исходную, пишет путь в LAST_BACKUP
  [[ -n "$LAST_BACKUP" ]] || die "Образ не создан — клонирование отменено."

  echo
  warn "Если у тебя ОДИН USB-порт — выньте исходную флешку и вставьте целевую сейчас."
  warn "Если портов два — целевая флешка уже видна; на след. шаге выбери именно ЕЁ (не исходную!)."
  local k; read -rp "Когда целевая флешка на месте — нажми Enter (или q для отмены): " k < /dev/tty
  [[ "$k" == "q" ]] && exit 0

  do_restore "$LAST_BACKUP"
}

# ----------------------------------------------------------------------------
# Точка входа
# ----------------------------------------------------------------------------
MODE="${1:-}"
if [[ -z "$MODE" ]]; then
  printf "%sЧто сделать?%s\n" "$c_cyn" "$c_rst"
  echo "  1) backup  — снять образ флешки в файл"
  echo "  2) restore — записать образ из файла на флешку"
  echo "  3) clone   — снять образ и сразу залить на другую флешку"
  read -rp "Номер (1/2/3): " m < /dev/tty
  case "$m" in
    1) MODE="backup" ;;
    2) MODE="restore" ;;
    3) MODE="clone" ;;
    *) die "Некорректный выбор." ;;
  esac
fi

case "$MODE" in
  backup)  do_backup ;;
  restore) shift || true; do_restore "${1:-}" ;;
  clone)   do_clone ;;
  *) die "Использование: backup.sh {backup|restore [файл]|clone}" ;;
esac
