#!/usr/bin/env bash
#
# backup-linux.sh — умный бэкап/восстановление/клон USB-флешки Keenetic (Entware/XKeen).
# Платформа: Linux (нативный десктоп) И WSL2 внутри Windows.
#
# Порт macOS-версии (backup.sh) на Linux-инструменты. Формат образа .kbak ИДЕНТИЧЕН
# macOS-версии (tar.gz: mbr.bin + opkg.e2img + meta.txt) — образ, снятый на маке,
# разворачивается на Linux и наоборот.
#
# Как и на macOS: копируем только ЗАНЯТЫЕ блоки ext4 (через e2image) — образ маленький,
# снятие быстрое. Перед снятием ФС проверяется (e2fsck -fn) и ужимается до реального
# объёма (resize2fs), чтобы restore писал мегабайты, а не десятки гигабайт нулей.
# Swap не бэкапится — при restore раздел чистится, а mkswap делает router-setup.sh на роутере.
#
# Режимы (как в backup.sh):
#   backup-linux.sh                 — меню (backup / restore / clone)
#   backup-linux.sh backup          — снять образ флешки в файл (.kbak)
#   backup-linux.sh restore [файл]  — развернуть образ на флешку (СТИРАЕТ её)
#   backup-linux.sh clone           — снять образ и сразу залить на другую флешку
#
# Переменные окружения (используются обёрткой backup.ps1 в WSL и опытными Linux-юзерами):
#   DEV=/dev/sdX    — целевое устройство (пропустить интерактивный выбор диска).
#   ASSUME_YES=1    — не спрашивать подтверждение устройства (обёртка уже подтвердила).
#   KBAK_OUT=path   — куда положить .kbak при backup (обёртка задаёт путь на /mnt/c/...).
#   DRY_RUN=1       — ничего не писать на диск.
#   NO_SHRINK=1     — не ужимать ФС перед снятием образа (аварийный тумблер).
#
# ---- КОНТРАКТ ДЛЯ backup.ps1 (WSL2-обёртка) --------------------------------------
#   BACKUP :  DEV=/dev/sdX ASSUME_YES=1 KBAK_OUT=/mnt/c/Temp/<имя>.kbak \
#               bash backup-linux.sh backup
#   RESTORE:  (обёртка сперва кладёт .kbak в /mnt/c/Temp/x.kbak, затем)
#             DEV=/dev/sdX ASSUME_YES=1 bash backup-linux.sh restore /mnt/c/Temp/x.kbak
#   CLONE  :  в WSL проброс одного диска за раз, поэтому clone оркеструет обёртка
#             (backup source -> detach -> attach target -> restore). Здесь clone
#             рассчитан на нативный Linux, где обе флешки видны одновременно.
# ---------------------------------------------------------------------------------
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
NO_SHRINK="${NO_SHRINK:-0}"
DEV="${DEV:-}"                 # целевое устройство из окружения (для обёртки)
KBAK_OUT="${KBAK_OUT:-}"       # куда положить .kbak при backup (для обёртки)
SWAP_SIZE_MB=1024
EXT4_LABEL="OPKG"
WORKDIR="$(mktemp -d)"
LAST_BACKUP=""                 # путь к последнему снятому образу (для режима clone)

# --- Состояние ужатия ФС (см. shrink_fs/grow_fs) — как в macOS-версии ---
SHRUNK_DEV=""                  # блок-устройство с ВРЕМЕННО ужатой ФС; пусто = ужатия нет
SHRUNK_FS_BYTES=""             # размер ужатой ФС в байтах (пойдёт в meta.txt)
FS_IS_CLEAN=0                  # 1 — e2fsck подтвердил чистоту (без этого ужимать нельзя)
FS_NOT_GROWN=0                 # 1 — при restore ФС не удалось растянуть на весь раздел

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

# Ловушка: если скрипт падает/прерывается между shrink и grow — вернуть ФС на место.
# INT/TERM тоже, иначе Ctrl-C посреди e2image оставит флешку с ужатой ФС.
cleanup() { grow_fs || true; rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

# ----------------------------------------------------------------------------
# 0. Окружение: только Linux; поднять root; определить WSL
# ----------------------------------------------------------------------------
[[ "$(uname -s)" == "Linux" ]] || die "Этот скрипт для Linux/WSL. На macOS используй backup.sh."

if [[ $EUID -ne 0 ]]; then
  info "Нужны права root — перезапускаю через sudo..."
  exec sudo -E bash "$0" "$@"
fi

TTY="/dev/tty"; [[ -e "$TTY" ]] || TTY="/dev/stdin"

IS_WSL=0
if grep -qiE "(microsoft|wsl)" /proc/sys/kernel/osrelease 2>/dev/null; then IS_WSL=1; fi
[[ "$IS_WSL" == "1" ]] && info "Обнаружен WSL — ок."

# Кому вернуть владение файлом .kbak (нативный Linux, запуск через sudo)
OWNER_UID="${SUDO_UID:-0}"; OWNER_GID="${SUDO_GID:-0}"

# ----------------------------------------------------------------------------
# 1. Зависимости: e2fsprogs (e2image/e2fsck/resize2fs), util-linux (sfdisk/wipefs/
#    lsblk/blkid/blockdev), curl не нужен (ничего не качаем), tar/gzip — из base.
# ----------------------------------------------------------------------------
ensure_deps() {
  local need=()
  command -v e2image  >/dev/null 2>&1 || need+=("e2fsprogs")
  command -v e2fsck   >/dev/null 2>&1 || need+=("e2fsprogs")
  command -v resize2fs>/dev/null 2>&1 || need+=("e2fsprogs")
  command -v sfdisk   >/dev/null 2>&1 || need+=("util-linux")
  command -v wipefs   >/dev/null 2>&1 || need+=("util-linux")
  command -v lsblk    >/dev/null 2>&1 || need+=("util-linux")
  command -v blkid    >/dev/null 2>&1 || need+=("util-linux")
  command -v blockdev >/dev/null 2>&1 || need+=("util-linux")

  # уникализируем список пакетов
  local uniq=(); local p u seen
  for p in "${need[@]:-}"; do
    [[ -z "$p" ]] && continue
    seen=0; for u in "${uniq[@]:-}"; do [[ "$u" == "$p" ]] && seen=1; done
    [[ "$seen" == "0" ]] && uniq+=("$p")
  done
  [[ ${#uniq[@]} -eq 0 ]] && return 0

  if command -v apt-get >/dev/null 2>&1; then
    info "Устанавливаю зависимости: ${uniq[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq \
      || die "apt-get update не прошёл (нет интернета в WSL/Linux?)."
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${uniq[@]}" \
      || die "Не удалось установить: ${uniq[*]}"
  else
    die "Не хватает: ${uniq[*]}. Установи вручную (в контролируемой среде ожидался apt)."
  fi
}

E2IMAGE=""; E2FSCK=""; RESIZE2FS=""
ensure_tools() {
  [[ -n "$E2IMAGE" ]] && return 0
  ensure_deps
  E2IMAGE="$(command -v e2image || true)"
  [[ -n "$E2IMAGE" ]] || die "Не удалось подготовить e2image (пакет e2fsprogs)."
  ok "e2image:  $E2IMAGE"
  E2FSCK="$(command -v e2fsck || true)"
  RESIZE2FS="$(command -v resize2fs || true)"
  [[ -n "$E2FSCK"    ]] && ok "e2fsck:    $E2FSCK"    || warn "e2fsck не найден — проверка ФС будет пропущена."
  [[ -n "$RESIZE2FS" ]] && ok "resize2fs: $RESIZE2FS" || warn "resize2fs не найден — ужатие/растяжка отключены."
}

# ----------------------------------------------------------------------------
# 2. Хелперы устройства (перенесены из prepare-linux.sh)
# ----------------------------------------------------------------------------
# Имя раздела: /dev/sdb -> /dev/sdb1 ; /dev/nvme0n1|/dev/mmcblk0 -> ...p1
part_dev() {
  local d="$1" n="$2"
  if [[ "$d" =~ [0-9]$ ]]; then echo "${d}p${n}"; else echo "${d}${n}"; fi
}

disk_size_bytes() { blockdev --getsize64 "$1" 2>/dev/null || echo ""; }

root_disk() {
  local src pk
  src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ -z "$src" || "$src" != /dev/* ]] && { echo ""; return; }
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)"
  [[ -n "$pk" ]] && echo "/dev/$pk" || echo "$src"
}
ROOT_DISK="$(root_disk)"

disk_desc() {
  local d="$1" sz model
  sz="$(lsblk -dno SIZE "$d" 2>/dev/null | tr -d ' ' || true)"
  model="$(lsblk -dno MODEL "$d" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
  [[ -z "$model" ]] && model="(без модели)"
  echo "$model, $sz"
}

assert_safe_target() {
  local d="$1"
  [[ -b "$d" ]] || die "Устройство $d не найдено (не блочное)."
  local dtype=""
  dtype="$(lsblk -dno TYPE "$d" 2>/dev/null | head -n1 || true)"
  if [[ -z "$dtype" ]]; then
    case "$d" in
      *[0-9]p[0-9]*)       dtype="part" ;;
      /dev/sd[a-z][0-9]*)  dtype="part" ;;
      *)                   dtype="disk" ;;
    esac
    warn "lsblk не отдал тип для $d (WSL) — определил по имени: $dtype"
  fi
  case "$dtype" in
    disk|loop) : ;;
    part) die "$d — это раздел, а не целый диск. Укажи весь диск (напр. /dev/sdb)." ;;
    *)    die "$d — неподходящий тип устройства ('$dtype'). Нужен целый диск." ;;
  esac
  if [[ -n "$ROOT_DISK" && "$d" == "$ROOT_DISK" ]]; then
    die "$d — системный диск (на нём корень '/'). Отказ."
  fi
  local mp
  while IFS= read -r mp; do
    [[ -z "$mp" ]] && continue
    case "$mp" in
      /|/boot|/boot/*) die "На $d смонтировано '$mp' — похоже на системный диск. Отказ." ;;
    esac
  done < <(lsblk -nlo MOUNTPOINT "$d" 2>/dev/null)
}

unmount_all() {
  local d="$1" p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    umount "/dev/$p" 2>/dev/null || true
  done < <(lsblk -nlo NAME "$d" 2>/dev/null | tail -n +2)
  swapoff "$d"* 2>/dev/null || true
}

# Найти ext4-раздел OPKG на диске. Приоритет — по метке (надёжно), затем 2-й раздел.
find_ext4_part() {
  local disk="$1" bylabel p2
  bylabel="$(blkid -t LABEL="$EXT4_LABEL" -o device 2>/dev/null \
             | grep -E "^${disk}(p?2|[0-9])$" | head -n1 || true)"
  if [[ -n "$bylabel" && -b "$bylabel" ]]; then echo "$bylabel"; return 0; fi
  p2="$(part_dev "$disk" 2)"
  [[ -b "$p2" ]] && { echo "$p2"; return 0; }
  return 1
}

# ----------------------------------------------------------------------------
# 3. Выбор диска / файла
# ----------------------------------------------------------------------------
# Возвращает /dev/sdX. Если задан DEV — берём его (для обёртки), иначе интерактив.
pick_disk() {
  local prompt="$1"
  if [[ -n "$DEV" ]]; then echo "$DEV"; return 0; fi
  local CANDIDATES=() name dtype dtran drm i d choice
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    dtype="$(lsblk -dno TYPE "$name" 2>/dev/null | head -n1 || true)"
    [[ "$dtype" == "disk" || -z "$dtype" ]] || continue
    dtran="$(lsblk -dno TRAN "$name" 2>/dev/null | head -n1 || true)"
    drm="$(lsblk -dno RM "$name" 2>/dev/null | head -n1 || true)"
    [[ "$dtran" == "usb" || "$drm" == "1" ]] || continue
    [[ -n "$ROOT_DISK" && "$name" == "$ROOT_DISK" ]] && continue
    CANDIDATES+=("$name")
  done < <(lsblk -dpno NAME 2>/dev/null)
  [[ ${#CANDIDATES[@]} -gt 0 ]] || die "Съёмные USB-накопители не найдены. Вставь флешку."
  printf "%s%s%s\n" "$c_cyn" "$prompt" "$c_rst" >&2
  i=1
  for d in "${CANDIDATES[@]}"; do
    printf "  %s%d)%s %s — %s\n" "$c_grn" "$i" "$c_rst" "$d" "$(disk_desc "$d")" >&2
    i=$((i+1))
  done
  read -rp "Номер накопителя (или q): " choice < "$TTY"
  [[ "$choice" == "q" ]] && exit 0
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#CANDIDATES[@]} )) || die "Некорректный выбор."
  echo "${CANDIDATES[$((choice-1))]}"
}

pick_backup_file() {
  local files=() f i choice
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(find "$PWD" -maxdepth 1 -type f -name '*.kbak' 2>/dev/null | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    warn "Файлы .kbak рядом не найдены — введи ПОЛНЫЙ путь вручную." >&2
    read -rp "Путь к файлу образа (.kbak): " f < "$TTY"
    echo "$f"; return 0
  fi
  printf "%sВыбери файл образа для восстановления:%s\n" "$c_cyn" "$c_rst" >&2
  i=1
  for f in "${files[@]}"; do
    printf "  %s%d)%s %s  (%s, %s)\n" "$c_grn" "$i" "$c_rst" "$f" \
      "$(du -h "$f" 2>/dev/null | cut -f1)" \
      "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null)" >&2
    i=$((i+1))
  done
  printf "  %sp)%s ввести путь вручную\n" "$c_grn" "$c_rst" >&2
  read -rp "Номер файла (или p / q): " choice < "$TTY"
  [[ "$choice" == "q" ]] && exit 0
  if [[ "$choice" == "p" ]]; then
    read -rp "Путь к файлу образа (.kbak): " f < "$TTY"; echo "$f"; return 0
  fi
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#files[@]} )) || die "Некорректный выбор."
  echo "${files[$((choice-1))]}"
}

# ----------------------------------------------------------------------------
# 4. Предчек / ужатие / растяжка ФС (порт из backup.sh; на Linux — прямо по блок-устройству)
# ----------------------------------------------------------------------------
fsck_precheck() {
  local part="$1" rc=0 ans fy_rc=0
  if [[ -z "$E2FSCK" ]]; then
    warn "Пропускаю проверку ФС (нет e2fsck)."
    return 0
  fi
  info "Проверяю ФС перед снятием образа (e2fsck -fn, только чтение)..."
  if [[ "$DRY_RUN" == "1" ]]; then warn "(dry-run) $E2FSCK -fn $part"; return 0; fi
  "$E2FSCK" -fn "$part" > "$WORKDIR/fsck.log" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then ok "ФС чистая — снимаю образ."; FS_IS_CLEAN=1; return 0; fi
  echo
  warn "e2fsck вернул код $rc — ФС не в порядке (грязный журнал или ошибки)."
  tail -15 "$WORKDIR/fsck.log" >&2 || true
  echo
  warn "Снимать образ с битой ФС опасно: e2image может упасть или унести мусор."
  read -rp "Что делать? [f] починить (e2fsck -fy)  [c] продолжить как есть  [q] выход: " ans < "$TTY"
  case "$ans" in
    f|F)
      info "Чиню ФС (e2fsck -fy)..."
      # Коды e2fsck — битовая маска: 0 — чисто; 1 — ошибки ИСПРАВЛЕНЫ (норма);
      # 2 — исправлены + просьба о перезагрузке (для флешки неважно);
      # 4 — часть ошибок осталась; 8/16/32 — сбой/синтаксис/прервано.
      fy_rc=0
      "$E2FSCK" -fy "$part" || fy_rc=$?
      case "$fy_rc" in
        0)   ok   "e2fsck: ошибок не найдено." ;;
        1|2) ok   "e2fsck: ошибки найдены и исправлены (код $fy_rc — это норма после починки)." ;;
        *)   warn "e2fsck вернул код $fy_rc — часть ошибок могла остаться (4 — не исправлено, 8 — сбой, 16 — синтаксис, 32 — прервано)." ;;
      esac
      if "$E2FSCK" -fn "$part" >/dev/null 2>&1; then ok "ФС чистая."; FS_IS_CLEAN=1
      else warn "ФС всё ещё с ошибками — продолжаю на твой риск."; fi ;;
    c|C) warn "Продолжаю без починки (на твой риск). Ужатие ФС будет пропущено." ;;
    *)   die "Отмена." ;;
  esac
  return 0
}

# Проиграть журнал ФС ПЕРЕД снятием образа. Сам e2image журнал не проигрывает,
# а e2fsck -fn его не проигрывает и о нём не сообщает (N-1, N-2) — без этого шага
# непроигранный журнал молча уезжает в .kbak (N-3). К ужатию отношения не имеет:
# нужен и при NO_SHRINK=1, и когда resize2fs вовсе нет.
replay_journal() {
  local part="$1"
  [[ "$DRY_RUN" == "1" ]] && { warn "(dry-run) e2fsck -fy $part (проигрывание журнала)"; return 0; }
  [[ -z "$E2FSCK" ]] && { warn "Нет e2fsck — журнал не проигран, образ может содержать непроигранный журнал."; return 0; }
  # FS_IS_CLEAN != 1 — пользователь ответил [c] в fsck_precheck. Его выбор не переигрываем.
  [[ "$FS_IS_CLEAN" != "1" ]] && { warn "ФС не подтверждена как чистая — журнал не трогаю (твой выбор)."; return 0; }
  info "Проигрываю журнал ФС перед снятием образа (e2fsck -fy)..."
  "$E2FSCK" -fy "$part" >/dev/null 2>&1 || true
  return 0
}

# Ужать ФС до реального объёма ПЕРЕД снятием образа (restore тогда пишет мегабайты).
# Журнал к этому моменту уже проигран в replay_journal — resize2fs -P этого требует.
shrink_fs() {
  local part="$1" min_blocks target out blocks ksz
  [[ "$NO_SHRINK" == "1" ]] && { info "Ужатие ФС отключено (NO_SHRINK=1)."; return 1; }
  [[ "$DRY_RUN" == "1" ]]  && { warn "(dry-run) resize2fs -P + ужатие ФС"; return 1; }
  [[ -z "$RESIZE2FS" ]] && { warn "Нет resize2fs — ужатие пропускаю (restore медленнее, но корректно)."; return 1; }
  [[ "$FS_IS_CLEAN" != "1" ]] && { warn "ФС не подтверждена как чистая — ужатие пропускаю."; return 1; }
  min_blocks="$("$RESIZE2FS" -P "$part" 2>/dev/null \
                | sed -n 's/.*minimum size of the filesystem: *\([0-9][0-9]*\).*/\1/p' | head -1)"
  if [[ ! "$min_blocks" =~ ^[0-9]+$ ]] || [[ "$min_blocks" -le 0 ]]; then
    warn "Не удалось узнать минимальный размер ФС — ужатие пропускаю."; return 1
  fi
  # Запас: resize2fs -P систематически занижает. Берём +30% и не меньше +8192 блоков.
  target=$(( min_blocks * 13 / 10 ))
  [[ "$target" -lt $(( min_blocks + 8192 )) ]] && target=$(( min_blocks + 8192 ))
  info "Ужимаю ФС перед снятием образа (минимум $min_blocks бл., беру $target бл.)..."
  SHRUNK_DEV="$part"     # ставим ДО вызова: упадёт на полпути — ловушка вернёт ФС
  if ! out="$("$RESIZE2FS" "$part" "$target" 2>&1)"; then
    warn "resize2fs не смог ужать ФС:"; printf '%s\n' "$out" | tail -5 >&2
    grow_fs || true; return 1
  fi
  blocks="$(printf '%s\n' "$out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) (\([0-9][0-9]*\)k) blocks long.*/\1/p' | head -1)"
  ksz="$(   printf '%s\n' "$out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) (\([0-9][0-9]*\)k) blocks long.*/\2/p' | head -1)"
  if [[ ! "$blocks" =~ ^[0-9]+$ ]] || [[ ! "$ksz" =~ ^[0-9]+$ ]]; then
    warn "Не разобрал вывод resize2fs — возвращаю ФС и продолжаю без ужатия."
    printf '%s\n' "$out" | tail -5 >&2; grow_fs || true; return 1
  fi
  SHRUNK_FS_BYTES=$(( blocks * ksz * 1024 ))
  ok "ФС ужата до $blocks блоков по ${ksz}k = $(( SHRUNK_FS_BYTES / 1024 / 1024 )) МБ."
  return 0
}

# Вернуть ужатую ФС на весь раздел. Идемпотентна. Вызывается штатно и из ловушки.
grow_fs() {
  local part="$SHRUNK_DEV"
  [[ -n "$part" ]] || return 0
  SHRUNK_DEV=""          # сбрасываем СРАЗУ — иначе ловушка зациклится
  [[ -z "$RESIZE2FS" ]] && return 0
  echo
  info "Возвращаю ФС на весь раздел ($part)..."
  [[ -n "$E2FSCK" ]] && "$E2FSCK" -fy "$part" >/dev/null 2>&1 || true
  if "$RESIZE2FS" "$part" >/dev/null 2>&1; then
    ok "ФС восстановлена на полный размер раздела."
  else
    warn "Не удалось растянуть ФС обратно! Флешка РАБОТОСПОСОБНА, данные целы,"
    warn "но ФС меньше раздела. Растянуть вручную: $RESIZE2FS $part"
  fi
  return 0
}

# ----------------------------------------------------------------------------
# 5. BACKUP
#   finish: mount (по умолчанию) | eject (для clone — на нативном Linux power-off)
# ----------------------------------------------------------------------------
do_backup() {
  ensure_tools
  local finish="${1:-mount}"
  local DISK P2 OUT STAGE ext4_part_bytes
  DISK="$(pick_disk 'Выбери флешку для СНЯТИЯ образа:')"
  assert_safe_target "$DISK"
  info "Источник: $DISK ($(disk_desc "$DISK"))"

  P2="$(find_ext4_part "$DISK")" || die "Не нашёл ext4-раздел (метка $EXT4_LABEL / второй раздел) на $DISK."
  info "ext4-раздел: $P2"
  ext4_part_bytes="$(disk_size_bytes "$P2")"

  OUT="keenetic-backup-$(date +%Y%m%d-%H%M).kbak"
  STAGE="$WORKDIR/stage"; mkdir -p "$STAGE"

  info "Размонтирую всё с $DISK..."
  run "unmount_all $DISK"

  # 0. Предчек ФС ДО снятия образа (защита от битого .kbak)
  fsck_precheck "$P2"
  run "unmount_all $DISK"

  # 0.4. Проиграть журнал (нужно даже при NO_SHRINK=1 — иначе он уедет в образ)
  replay_journal "$P2"

  # 0.5. Ужать ФС до реального объёма
  shrink_fs "$P2" || true

  # 1. Таблица разделов (первый 1 МБ)
  info "Сохраняю таблицу разделов..."
  run "dd if=$DISK of=$STAGE/mbr.bin bs=1M count=1 status=none"

  # 2. ext4 через e2image -ra (raw-образ: занятые блоки + данные, пустое пропускается)
  info "Снимаю умный образ ext4 (занятые блоки + данные)..."
  run "$E2IMAGE -ra $P2 $STAGE/opkg.e2img"

  # 2.5. ФС источника — обратно на весь раздел, СРАЗУ после e2image
  grow_fs

  # 3. Метаданные (те же ключи, что в macOS-версии — .kbak кросс-совместим)
  if [[ "$DRY_RUN" != "1" ]]; then
    {
      echo "source_disk_bytes=$(disk_size_bytes "$DISK")"
      echo "ext4_part_bytes=${ext4_part_bytes}"
      # ext4_fs_bytes — размер УЖАТОЙ ФС; пишется только если ужатие удалось.
      [[ -n "$SHRUNK_FS_BYTES" ]] && echo "ext4_fs_bytes=${SHRUNK_FS_BYTES}"
      echo "ext4_label=${EXT4_LABEL}"
      echo "swap_label=SWAP"
      echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$STAGE/meta.txt"
    tar -czf "$OUT" -C "$STAGE" mbr.bin opkg.e2img meta.txt
    # Обёртка задаёт KBAK_OUT (путь на /mnt/c/...) — перемещаем туда.
    if [[ -n "$KBAK_OUT" ]]; then
      mkdir -p "$(dirname "$KBAK_OUT")" 2>/dev/null || true
      mv -f "$OUT" "$KBAK_OUT" && OUT="$KBAK_OUT"
    fi
    # На нативном Linux вернём владение файлом обычному пользователю (после sudo).
    [[ "$OWNER_UID" != "0" ]] && chown "$OWNER_UID:$OWNER_GID" "$OUT" 2>/dev/null || true
    ok "Образ снят: $OUT ($(du -h "$OUT" | cut -f1))"
  else
    warn "(dry-run) tar -czf $OUT mbr.bin opkg.e2img meta.txt"
  fi

  LAST_BACKUP="$OUT"
  [[ "$LAST_BACKUP" != /* ]] && LAST_BACKUP="$PWD/$OUT"

  # Финал: в WSL диск отсоединит обёртка; на нативном Linux при eject — power-off.
  if [[ "$IS_WSL" != "1" ]]; then
    if [[ "$finish" == "eject" ]]; then
      run "udisksctl power-off -b $DISK 2>/dev/null || true"
      info "Исходную флешку можно вынимать."
    fi
  fi
  echo
  if [[ "$DRY_RUN" == "1" ]]; then
    ok "Готово (dry-run) — файл НЕ создавался, на диск ничего не записано."
  else
    ok "Готово. Файл: $LAST_BACKUP"
    info "Из него можно восстановить/клонировать флешку."
  fi
}

# ----------------------------------------------------------------------------
# 6. RESTORE
#   На Linux e2image -ra пишет ПРЯМО в блок-устройство (без промежуточного файла+dd,
#   как приходилось на macOS). После — e2fsck + resize2fs растянуть на весь раздел.
# ----------------------------------------------------------------------------
do_restore() {
  ensure_tools
  local IMG="${1:-}"
  [[ -n "$IMG" ]] || IMG="$(pick_backup_file)"
  [[ -f "$IMG" ]] || die "Файл образа не найден: $IMG"
  info "Образ: $IMG"

  local STAGE="$WORKDIR/restore"; mkdir -p "$STAGE"
  tar -xzf "$IMG" -C "$STAGE" || die "Не удалось распаковать образ."
  [[ -f "$STAGE/opkg.e2img" ]] || die "Образ повреждён (нет opkg.e2img)."

  local src_bytes src_ext4_bytes fs_was_shrunk=0
  src_bytes="$(awk -F= '/^source_disk_bytes=/{print $2}' "$STAGE/meta.txt" 2>/dev/null)"
  src_ext4_bytes="$(awk -F= '/^ext4_fs_bytes=/{print $2}' "$STAGE/meta.txt" 2>/dev/null)"
  if [[ -n "$src_ext4_bytes" ]]; then
    fs_was_shrunk=1
    info "Образ с ужатой ФС ($(( src_ext4_bytes / 1024 / 1024 )) МБ) — запись быстрая."
  else
    src_ext4_bytes="$(awk -F= '/^ext4_part_bytes=/{print $2}' "$STAGE/meta.txt" 2>/dev/null)"
  fi

  local DISK P1 P2
  DISK="$(pick_disk 'Выбери флешку для ЗАПИСИ образа (будет СТЁРТА):')"
  assert_safe_target "$DISK"

  # Проверка вместимости на уровне диска (точная проверка по разделу — ниже, после разметки).
  local dst_bytes; dst_bytes="$(disk_size_bytes "$DISK")"
  if [[ "$fs_was_shrunk" != "1" ]]; then
    if [[ -n "$src_bytes" && -n "$dst_bytes" && "$src_bytes" -gt "$dst_bytes" ]]; then
      die "Образ снят с флешки $src_bytes Б, целевая — $dst_bytes Б. Нужна флешка не меньше исходной."
    fi
  fi

  echo
  warn "Диск $DISK ($(disk_desc "$DISK")) будет ПОЛНОСТЬЮ СТЁРТ."
  if [[ "$ASSUME_YES" != "1" ]]; then
    local confirm; read -rp "Для подтверждения введи ровно '$DISK': " confirm < "$TTY"
    [[ "$confirm" == "$DISK" ]] || die "Подтверждение не совпало. Отмена."
  else
    info "ASSUME_YES=1 — подтверждение устройства пропущено (подтверждено обёрткой)."
  fi

  P1="$(part_dev "$DISK" 1)"   # swap
  P2="$(part_dev "$DISK" 2)"   # ext4 OPKG

  info "Размонтирую всё с $DISK..."
  run "unmount_all $DISK"
  info "Очищаю старые сигнатуры на $DISK..."
  run "wipefs -a $DISK >/dev/null 2>&1 || true"

  # 1. Разметка: swap 1024M (0x82) + ext4 остаток (0x83) — как prepare-linux.sh.
  info "Создаю разметку (swap ${SWAP_SIZE_MB}M + ext4 остаток)..."
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "(dry-run) sfdisk $DISK <<< 'label: dos / ,${SWAP_SIZE_MB}M,82 / ,,83'"
  else
    sfdisk "$DISK" >/dev/null <<SFDISK || die "sfdisk не смог разметить $DISK."
label: dos
,${SWAP_SIZE_MB}M,82
,,83
SFDISK
  fi
  run "sync"
  run "blockdev --rereadpt $DISK 2>/dev/null || partprobe $DISK 2>/dev/null || true"
  run "udevadm settle 2>/dev/null || true"
  if [[ "$DRY_RUN" != "1" ]]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -b "$P1" && -b "$P2" ]] && break; sleep 0.5; done
    [[ -b "$P2" ]] || die "Раздел $P2 не появился после разметки."
  fi

  # 2. Проверка вместимости ФС в целевой раздел.
  if [[ "$DRY_RUN" != "1" ]]; then
    local part_bytes; part_bytes="$(disk_size_bytes "$P2")"
    [[ -n "$part_bytes" ]] || die "Не удалось определить размер раздела $P2."
    if [[ -n "$src_ext4_bytes" && "$src_ext4_bytes" -gt "$part_bytes" ]]; then
      err "ФС образа: $(( src_ext4_bytes / 1024 / 1024 )) МБ, целевой раздел: $(( part_bytes / 1024 / 1024 )) МБ."
      die "Не влезает. Нужна флешка крупнее."
    fi
  fi

  # 3. Развернуть ext4 ПРЯМО в раздел (Linux e2image это умеет).
  info "Разворачиваю ext4 из образа в $P2..."
  run "$E2IMAGE -ra $STAGE/opkg.e2img $P2"
  ok "ext4 развёрнут на $P2."

  # 3.5. Растянуть ФС на весь раздел.
  FS_NOT_GROWN=0
  if [[ "$DRY_RUN" != "1" ]]; then
    if [[ -n "$RESIZE2FS" && -n "$E2FSCK" ]]; then
      info "Растягиваю ФС на весь раздел..."
      "$E2FSCK" -fy "$P2" >/dev/null 2>&1 || true   # resize2fs требует чистую ФС
      if "$RESIZE2FS" "$P2" >/dev/null 2>&1; then
        ok "ФС занимает весь раздел $P2."
      else
        warn "Не удалось растянуть ФС. Флешка рабочая, но ФС меньше раздела."; FS_NOT_GROWN=1
      fi
    else
      warn "Нет resize2fs/e2fsck — ФС осталась размера исходной."; FS_NOT_GROWN=1
    fi
  fi

  # 4. Почистить swap-раздел; swap-сигнатуру (mkswap) сделает роутер (паритет с prepare).
  info "Чищу swap-раздел $P1..."
  run "wipefs -a $P1 >/dev/null 2>&1 || true"
  run "dd if=/dev/zero of=$P1 bs=1M count=8 status=none"

  run "sync"
  if [[ "$IS_WSL" != "1" ]]; then
    run "udisksctl power-off -b $DISK 2>/dev/null || true"
  fi

  echo
  ok "Готово. Флешку можно вставить в роутер."
  info "Swap активируется на роутере (router-setup.sh сделает mkswap -L SWAP)."
  if [[ "$FS_NOT_GROWN" == "1" ]]; then
    echo
    warn "ФС НЕ растянута на весь раздел. Растянуть на роутере:"
    warn "  opkg install e2fsprogs resize2fs"
    warn "  DEV=\$(blkid | grep 'LABEL=\"OPKG\"' | cut -d: -f1); e2fsck -f \$DEV && resize2fs \$DEV"
  else
    info "ФС уже растянута на весь раздел — ничего доделывать не нужно."
  fi
}

# ----------------------------------------------------------------------------
# 7. CLONE — снять образ с одной флешки и сразу залить на другую.
#   Рассчитан на нативный Linux (обе флешки видны). В WSL clone оркеструет backup.ps1.
# ----------------------------------------------------------------------------
do_clone() {
  [[ -n "$DEV" ]] && die "Режим clone несовместим с DEV=... (в WSL clone оркеструет обёртка)."
  info "Режим КЛОН: снимем образ с исходной флешки и сразу зальём на целевую."
  echo
  do_backup eject
  [[ -n "$LAST_BACKUP" && -f "$LAST_BACKUP" ]] || die "Образ не создан — клонирование отменено."
  echo
  warn "Если один USB-порт — выньте исходную и вставьте целевую флешку сейчас."
  warn "Если портов два — на след. шаге выбери именно ЦЕЛЕВУЮ (не исходную!)."
  local k; read -rp "Когда целевая флешка на месте — нажми Enter (или q): " k < "$TTY"
  [[ "$k" == "q" ]] && exit 0
  do_restore "$LAST_BACKUP"
}

# ----------------------------------------------------------------------------
# 8. Точка входа
# ----------------------------------------------------------------------------
MODE="${1:-}"
if [[ -z "$MODE" ]]; then
  printf "%sЧто сделать?%s\n" "$c_cyn" "$c_rst"
  echo "  1) backup  — снять образ флешки в файл"
  echo "  2) restore — записать образ из файла на флешку"
  echo "  3) clone   — снять образ и сразу залить на другую флешку"
  read -rp "Номер (1/2/3): " m < "$TTY"
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
  *) die "Использование: backup-linux.sh {backup|restore [файл]|clone}" ;;
esac
