#!/usr/bin/env bash
#
# keenetic-entware-flash — подготовка USB-флешки под Entware для роутеров Keenetic
# Платформа: Linux (нативный десктоп) И WSL2 внутри Windows.
#
# Порт macOS-версии (prepare.sh) на Linux-инструменты. Результат идентичен:
#   MBR: p1 = swap 1024M (0x82), p2 = ext4 "OPKG" (0x83),
#   installer -> /install/<arch>-installer.tar.gz (через debugfs, без монтирования).
#
# Два режима запуска:
#   1) Явное устройство (используется обёрткой prepare.ps1 в WSL, и опытными Linux-юзерами):
#        sudo bash prepare-linux.sh /dev/sdX
#   2) Интерактивный выбор (нативный Linux-десктоп):
#        sudo bash prepare-linux.sh
#
# Тест без записи на диск (скачивания при этом выполняются — это безопасно):
#   DRY_RUN=1 bash prepare-linux.sh /dev/sdX
#
# Автоматизация (пропустить набор-подтверждение устройства — обёртка уже
# подтвердила выбор на стороне Windows):
#   ASSUME_YES=1 bash prepare-linux.sh /dev/sdX
#
# NB: 'sudo -E' НЕ использовать — на Ubuntu 24.04+/26.04 sudo игнорирует -E и
# переменные теряются. Скрипт сам перезапустится через sudo, передав их явно.
# Запускать из-под обычного пользователя: переменные ставятся ПЕРЕД bash.
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Настройки (сверены с prepare.sh — должны совпадать бит-в-бит по результату)
# ----------------------------------------------------------------------------
SWAP_SIZE_MB=1024
EXT4_LABEL="OPKG"
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

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

# Сетевой сбой: в боевом прогоне фатален, в холостом — только предупреждение.
# Смысл холостого прогона — отрепетировать выбор диска и подтверждения, а не
# проверить связь; без интернета он должен доходить до конца, а не падать на
# первом же curl/apt. Когда сеть есть, URL проверяется как обычно.
net_fail() {
  [[ "$DRY_RUN" == "1" ]] || die "$*"
  warn "$*"
  warn "(dry-run) пропускаю этот шаг и иду дальше — на диск всё равно ничего не пишется."
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "   %s(dry-run)%s %s\n" "$c_yel" "$c_rst" "$*"
  else
    eval "$@"
  fi
}

usage() {
  cat <<USAGE
Использование:
  sudo bash prepare-linux.sh [/dev/sdX]

  Без аргумента — интерактивный выбор съёмного USB-накопителя.
  С аргументом  — подготовить указанное устройство (с подтверждением).

Переменные окружения:
  DRY_RUN=1     — ничего не писать на диск (скачивания выполняются, но их
                  сбой не фатален: без сети прогон идёт до конца).
  ASSUME_YES=1  — не спрашивать подтверждение устройства (для автоматизации).
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

# ----------------------------------------------------------------------------
# 0. Окружение: только Linux; поднять права root (если не под root — пере-запуск через sudo)
# ----------------------------------------------------------------------------
[[ "$(uname -s)" == "Linux" ]] || die "Этот скрипт для Linux/WSL. На macOS используй prepare.sh."

if [[ $EUID -ne 0 ]]; then
  info "Нужны права root — перезапускаю через sudo..."
  # ВАЖНО: 'sudo -E' здесь НЕ годится. На Ubuntu 24.04+/26.04 sudo отвечает
  # "preserving the entire environment is not supported, '-E' is ignored" —
  # и DRY_RUN/ARCH/ASSUME_YES молча теряются. Для DRY_RUN=1 это означало бы
  # продолжение как БОЕВОЙ запуск, то есть стёртую флешку вместо проверки.
  # Передаём переменные явно — это работает независимо от политики sudoers.
  exec sudo DRY_RUN="${DRY_RUN:-}" ARCH="${ARCH:-}" ASSUME_YES="${ASSUME_YES:-}" \
       bash "$0" "$@"
fi

# Интерактивный ввод читаем с /dev/tty (устойчиво к запуску через пайпы)
TTY="/dev/tty"; [[ -e "$TTY" ]] || TTY="/dev/stdin"

IS_WSL=0
if grep -qiE "(microsoft|wsl)" /proc/sys/kernel/osrelease 2>/dev/null; then IS_WSL=1; fi
[[ "$IS_WSL" == "1" ]] && info "Обнаружен WSL — ок."

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ----------------------------------------------------------------------------
# 1. Зависимости: e2fsprogs (mke2fs/debugfs), util-linux (sfdisk/lsblk/wipefs), curl
#    Контролируемая среда Ubuntu/Debian -> ставим через apt при отсутствии.
# ----------------------------------------------------------------------------
ensure_deps() {
  local need=()
  command -v mke2fs  >/dev/null 2>&1 || need+=("e2fsprogs")
  command -v debugfs >/dev/null 2>&1 || need+=("e2fsprogs")
  command -v sfdisk  >/dev/null 2>&1 || need+=("util-linux")
  command -v wipefs  >/dev/null 2>&1 || need+=("util-linux")
  command -v lsblk   >/dev/null 2>&1 || need+=("util-linux")
  command -v curl    >/dev/null 2>&1 || need+=("curl")

  # уникализируем список пакетов
  local uniq=(); local p seen
  for p in "${need[@]:-}"; do
    [[ -z "$p" ]] && continue
    seen=0; for u in "${uniq[@]:-}"; do [[ "$u" == "$p" ]] && seen=1; done
    [[ "$seen" == "0" ]] && uniq+=("$p")
  done

  [[ ${#uniq[@]} -eq 0 ]] && return 0

  if command -v apt-get >/dev/null 2>&1; then
    info "Устанавливаю зависимости: ${uniq[*]}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
      net_fail "apt-get update не прошёл (нет интернета в WSL/Linux?)."
      return 0
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${uniq[@]}"; then
      net_fail "Не удалось установить: ${uniq[*]}"
      return 0
    fi
  else
    # Отсутствие apt — не сетевая беда, а неподходящая среда: фатально всегда.
    die "Не хватает: ${uniq[*]}. Установи их вручную (в контролируемой среде ожидался apt)."
  fi
}
ensure_deps
# В холостом прогоне без сети пакетов может не быть — тогда путь пуст, и это
# не повод падать: ниже все команды записи всё равно только печатаются.
ok "mke2fs:  $(command -v mke2fs || echo '(не установлен — dry-run без сети)')"
ok "debugfs: $(command -v debugfs || echo '(не установлен — dry-run без сети)')"
ok "sfdisk:  $(command -v sfdisk || echo '(не установлен — dry-run без сети)')"

# ----------------------------------------------------------------------------
# 2. Хелперы устройства
# ----------------------------------------------------------------------------
# Имя раздела: /dev/sdb -> /dev/sdb1 ; /dev/nvme0n1|/dev/mmcblk0 -> ...p1
part_dev() {
  local d="$1" n="$2"
  if [[ "$d" =~ [0-9]$ ]]; then echo "${d}p${n}"; else echo "${d}${n}"; fi
}

# Диск, на котором стоит корень системы (его трогать НЕЛЬЗЯ)
root_disk() {
  local src pk
  src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ -z "$src" || "$src" != /dev/* ]] && { echo ""; return; }
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)"
  [[ -n "$pk" ]] && echo "/dev/$pk" || echo "$src"
}
ROOT_DISK="$(root_disk)"

# Человекочитаемое описание диска
disk_desc() {
  local d="$1" sz model
  sz="$(lsblk -dno SIZE "$d" 2>/dev/null | tr -d ' ' || true)"
  model="$(lsblk -dno MODEL "$d" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
  [[ -z "$model" ]] && model="(без модели)"
  echo "$model, $sz"
}

# Проверки безопасности перед стиранием
assert_safe_target() {
  local d="$1"
  [[ -b "$d" ]] || die "Устройство $d не найдено (не блочное)."
  # Тип устройства. В WSL2 lsblk часто НЕ отдаёт TYPE для loop и даже для
  # проброшенных дисков — поэтому: (1) не роняем скрипт пустым выводом,
  # (2) если тип пустой, определяем «диск vs раздел» по имени устройства.
  local dtype=""
  dtype="$(lsblk -dno TYPE "$d" 2>/dev/null | head -n1 || true)"
  if [[ -z "$dtype" ]]; then
    # имя раздела оканчивается на цифру у sdX (sdb1) или на pN у nvme/mmc/loop (nvme0n1p1, loop0p1)
    case "$d" in
      *[0-9]p[0-9]*) dtype="part" ;;                 # nvme0n1p1 / mmcblk0p1 / loop0p1
      /dev/sd[a-z][0-9]*) dtype="part" ;;            # sdb1
      *) dtype="disk" ;;                              # sdb / loop0 / nvme0n1 — целый диск
    esac
    warn "lsblk не отдал тип для $d (WSL) — определил по имени: $dtype"
  fi
  case "$dtype" in
    disk|loop) : ;;  # целый диск или loop-образ (тест) — ок
    part) die "$d — это раздел, а не целый диск. Укажи весь диск (напр. /dev/sdb, а не /dev/sdb1)." ;;
    *)    die "$d — неподходящий тип устройства ('$dtype'). Нужен целый диск." ;;
  esac
  if [[ -n "$ROOT_DISK" && "$d" == "$ROOT_DISK" ]]; then
    die "$d — системный диск (на нём корень '/'). Отказ."
  fi
  # Не даём стереть диск, где смонтирован / или /boot
  local mp
  while IFS= read -r mp; do
    [[ -z "$mp" ]] && continue
    case "$mp" in
      /|/boot|/boot/*) die "На $d смонтировано '$mp' — похоже на системный диск. Отказ." ;;
    esac
  done < <(lsblk -nlo MOUNTPOINT "$d" 2>/dev/null)
}

# Размонтировать всё, что автомонтировалось с целевого диска (нативный Linux)
unmount_all() {
  local d="$1" p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    umount "/dev/$p" 2>/dev/null || true
  done < <(lsblk -nlo NAME "$d" 2>/dev/null | tail -n +2)
  # на всякий случай выключим своп с этого диска
  swapoff "$d"* 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# 3. Выбор диска
# ----------------------------------------------------------------------------
DISK="${1:-}"

if [[ -z "$DISK" ]]; then
  # Интерактивный режим: показываем только съёмные USB-диски (нативный Linux)
  info "Ищу съёмные USB-накопители..."
  CANDIDATES=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    dtype="$(lsblk -dno TYPE "$name" 2>/dev/null | head -n1 || true)"
    [[ "$dtype" == "disk" ]] || continue
    dtran="$(lsblk -dno TRAN "$name" 2>/dev/null | head -n1 || true)"
    drm="$(lsblk -dno RM   "$name" 2>/dev/null | head -n1 || true)"
    [[ "$dtran" == "usb" || "$drm" == "1" ]] || continue
    [[ -n "$ROOT_DISK" && "$name" == "$ROOT_DISK" ]] && continue
    CANDIDATES+=("$name")
  done < <(lsblk -dpno NAME 2>/dev/null)

  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    err "Съёмные USB-накопители не найдены."
    [[ "$IS_WSL" == "1" ]] && err "В WSL передай устройство явно: prepare-linux.sh /dev/sdX (его подставляет prepare.ps1)."
    die "Вставь флешку и повтори, либо укажи /dev/sdX аргументом."
  fi

  echo
  printf "%sНайденные съёмные накопители:%s\n" "$c_cyn" "$c_rst"
  i=1
  for d in "${CANDIDATES[@]}"; do
    printf "  %s%d)%s %s — %s\n" "$c_grn" "$i" "$c_rst" "$d" "$(disk_desc "$d")"
    i=$((i+1))
  done
  echo
  read -rp "Номер накопителя (или q для выхода): " choice < "$TTY"
  [[ "$choice" == "q" ]] && exit 0
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#CANDIDATES[@]} )) \
    || die "Некорректный выбор."
  DISK="${CANDIDATES[$((choice-1))]}"
fi

assert_safe_target "$DISK"
DISK_DESC="$(disk_desc "$DISK")"

echo
warn "Диск $DISK ($DISK_DESC) будет ПОЛНОСТЬЮ СТЁРТ."
if [[ "$ASSUME_YES" != "1" ]]; then
  read -rp "Для подтверждения введи ровно '$DISK': " confirm < "$TTY"
  [[ "$confirm" == "$DISK" ]] || die "Подтверждение не совпало. Отмена."
else
  info "ASSUME_YES=1 — подтверждение устройства пропущено (подтверждено обёрткой)."
fi

# ----------------------------------------------------------------------------
# 4. Выбор архитектуры (ARCH из окружения -> без меню; иначе интерактивно)
# ----------------------------------------------------------------------------
set_installer_url() {
  case "$1" in
    mipsel)  INSTALLER_URL="$URL_MIPSEL"  ;;
    mips)    INSTALLER_URL="$URL_MIPS"    ;;
    aarch64) INSTALLER_URL="$URL_AARCH64" ;;
    *) return 1 ;;
  esac
  return 0
}

if [[ -n "${ARCH:-}" ]]; then
  set_installer_url "$ARCH" || die "ARCH='$ARCH' некорректна (ожидается mipsel|mips|aarch64)."
  info "Архитектура задана окружением: $ARCH (меню пропущено)."
else
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
  read -rp "Номер (1/2/3): " arch_choice < "$TTY"
  case "$arch_choice" in
    1) ARCH="mipsel"  ;;
    2) ARCH="mips"    ;;
    3) ARCH="aarch64" ;;
    *) die "Некорректный выбор архитектуры." ;;
  esac
  set_installer_url "$ARCH" || die "Внутренняя ошибка: неизвестная арка."
fi
INSTALLER_NAME="${ARCH}-installer.tar.gz"
ok "Архитектура: $ARCH"

# ----------------------------------------------------------------------------
# 5. Скачиваем installer заранее (до разметки — чтобы не стирать зря)
# ----------------------------------------------------------------------------
info "Скачиваю $INSTALLER_NAME ..."
if curl -fL --retry 3 -o "$WORKDIR/$INSTALLER_NAME" "$INSTALLER_URL"; then
  [[ -s "$WORKDIR/$INSTALLER_NAME" ]] || die "Скачанный installer пустой."
  ok "Installer готов ($(du -h "$WORKDIR/$INSTALLER_NAME" | cut -f1))"
else
  net_fail "Не удалось скачать installer. Проверь URL/интернет."
fi

# ----------------------------------------------------------------------------
# 6. Разметка: MBR, swap (0x82) первым, ext4 (0x83) — остаток. sfdisk ставит и размеры, и типы.
# ----------------------------------------------------------------------------
P1="$(part_dev "$DISK" 1)"   # swap
P2="$(part_dev "$DISK" 2)"   # ext4 OPKG

info "Размонтирую всё с $DISK..."
run "unmount_all $DISK"

info "Очищаю старые сигнатуры на $DISK..."
run "wipefs -a $DISK >/dev/null 2>&1 || true"

info "Создаю разметку MBR (swap ${SWAP_SIZE_MB}M + ext4 остаток)..."
if [[ "$DRY_RUN" == "1" ]]; then
  warn "(dry-run) sfdisk $DISK <<< 'label: dos / ,${SWAP_SIZE_MB}M,82 / ,,83'"
else
  sfdisk "$DISK" >/dev/null <<SFDISK || die "sfdisk не смог разметить $DISK."
label: dos
,${SWAP_SIZE_MB}M,82
,,83
SFDISK
fi

info "Перечитываю таблицу разделов..."
run "sync"
run "blockdev --rereadpt $DISK 2>/dev/null || partprobe $DISK 2>/dev/null || true"
run "udevadm settle 2>/dev/null || true"

# Ждём появления нод разделов (до ~5 сек) — только в боевом режиме
if [[ "$DRY_RUN" != "1" ]]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -b "$P1" && -b "$P2" ]] && break
    sleep 0.5
  done
  [[ -b "$P2" ]] || die "Раздел $P2 не появился после разметки."
fi

# ----------------------------------------------------------------------------
# 7. swap-раздел: чистим сигнатуры (роутер не должен принять его за VFAT).
#    mkswap НЕ делаем — своп активирует router-setup.sh на роутере (паритет с macOS-версией).
# ----------------------------------------------------------------------------
info "Чищу сигнатуры на swap-разделе $P1..."
run "wipefs -a $P1 >/dev/null 2>&1 || true"
run "dd if=/dev/zero of=$P1 bs=1M count=8 status=none"

# ----------------------------------------------------------------------------
# 8. Форматируем ext4 (те же флаги, что в macOS-версии)
# ----------------------------------------------------------------------------
info "Форматирую $P2 в ext4 (метка $EXT4_LABEL)..."
run "mke2fs -F -t ext4 -L $EXT4_LABEL -O ^64bit,^metadata_csum $P2 >/dev/null 2>&1"
ok "ext4 создан."

# ----------------------------------------------------------------------------
# 9. install/<arch>-installer.tar.gz через debugfs (без монтирования)
# ----------------------------------------------------------------------------
info "Записываю $INSTALLER_NAME в /install на ext4 (debugfs)..."
if [[ "$DRY_RUN" == "1" ]]; then
  warn "(dry-run) debugfs -w: mkdir /install; write $INSTALLER_NAME"
else
  debugfs -w "$P2" >/dev/null 2>&1 <<EOF
mkdir /install
cd /install
write $WORKDIR/$INSTALLER_NAME $INSTALLER_NAME
quit
EOF
  ok "Installer записан в install/$INSTALLER_NAME"
fi

# ----------------------------------------------------------------------------
# 10. Самопроверка результата
# ----------------------------------------------------------------------------
if [[ "$DRY_RUN" != "1" ]]; then
  echo
  info "Проверяю результат..."
  verify_ok=1

  ls_out="$(debugfs -R "ls -l /install" "$P2" 2>/dev/null || true)"
  if printf '%s' "$ls_out" | grep -q "$INSTALLER_NAME"; then
    ok "ext4 читается, install/$INSTALLER_NAME на месте."
  else
    err "Не вижу install/$INSTALLER_NAME на ext4-разделе!"
    verify_ok=0
  fi

  # Типы разделов: ждём 82 (swap) и 83 (Linux)
  types="$(sfdisk -d "$DISK" 2>/dev/null | sed -n 's/.*type=\([0-9A-Fa-f]*\).*/\1/p' | tr 'A-F' 'a-f' | paste -sd',' -)"
  if [[ "$types" == "82,83" ]]; then
    ok "Типы разделов корректны: swap=0x82, ext4=0x83."
  else
    warn "Типы разделов: [$types] (ожидалось 82,83). Не критично — роутер видит ext4 по ФС."
  fi

  [[ "$verify_ok" == "1" ]] || die "Проверка не прошла — разберёмся, диск не извлекаю."
fi

# ----------------------------------------------------------------------------
# 11. Финал
# ----------------------------------------------------------------------------
run "sync"
if [[ "$IS_WSL" == "1" ]]; then
  info "WSL: отсоединение диска сделает обёртка (wsl --unmount). Внутри WSL eject не нужен."
else
  # Нативный Linux — аккуратно выключаем/извлекаем, если умеем
  run "udisksctl power-off -b $DISK 2>/dev/null || true"
fi

echo
if [ "$DRY_RUN" = "1" ]; then
  ok "Dry-run завершён — диск НЕ тронут."
  cat <<DRYNEXT

${c_yel}Это была только проверка (DRY_RUN=1).${c_rst}
Флешка НЕ размечена и НЕ отформатирована — всё, что было бы записано,
показано выше строками «(dry-run) ...».
Чтобы выполнить по-настоящему — запусти ту же команду без DRY_RUN.
DRYNEXT
  exit 0
fi

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
     wget -T 15 -t 3 -qO- https://raw.githubusercontent.com/lastik9/keenetic-entware/main/router-setup.sh | sh

NEXT
