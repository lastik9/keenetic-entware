#!/bin/sh
#
# router-setup.sh — пост-установочная настройка роутера Keenetic/Netcraze под Entware + XKeen
# Запуск НА РОУТЕРЕ (после установки Entware), по SSH (порт 222).
#
# ВАЖНО: на чистом Entware нет ни curl, ни HTTPS-wget, поэтому сначала ставим
# wget-ssl, и только потом качаем этот скрипт. Две команды:
#
#   opkg update && opkg install wget-ssl ca-bundle ca-certificates
#   wget -T 15 -t 3 -qO- https://raw.githubusercontent.com/lastik9/keenetic-entware/main/router-setup.sh | sh
#
#
# МЕНЮ при запуске:
#   1) Полная настройка (swap + пакеты + vim) и установка XKeen
#   2) Только установка XKeen (GitHub, при сбое — jsDelivr)
#   3) Только swap (после восстановления флешки из бэкапа — быстрый путь)
#   4) Только фикс SSH-222 (протухший pid-файл dropbear)
#   q) Выход
#
# Окружение: BusyBox ash (не bash!). Только POSIX sh + возможности busybox.
# --- цвета (busybox поддерживает printf с escape) ---
C_G="$(printf '\033[32m')"; C_Y="$(printf '\033[33m')"; C_R="$(printf '\033[31m')"
C_C="$(printf '\033[36m')"; C_0="$(printf '\033[0m')"
info() { printf '%s[i]%s %s\n' "$C_C" "$C_0" "$*"; }
ok()   { printf '%s[v]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" 1>&2; }
die()  { err "$*"; exit 1; }
# Интерактивный ввод под `wget | sh`: читаем с терминала
TTY=/dev/tty
ask() { # ask "вопрос" -> ответ в stdout; пусто если нет tty
  _q="$1"
  if [ -e "$TTY" ]; then
    printf '%s' "$_q" > "$TTY"
    read _a < "$TTY"
    printf '%s' "$_a"
  fi
}
# Установщик XKeen с fallback: сначала GitHub, при недоступности — jsDelivr.
# Запуск через /dev/tty, т.к. установщик интерактивный, а наш stdin занят трубой.
XKEEN_GH="https://raw.githubusercontent.com/jameszeroX/XKeen/main/install.sh"
XKEEN_CDN="https://cdn.jsdelivr.net/gh/jameszeroX/XKeen@main/install.sh"
# Скачивание с таймаутами. Без --connect-timeout мёртвый IP вешает скрипт НАВСЕГДА:
# у raw.githubusercontent.com несколько A-записей, и часть из них может не отвечать
# (проверено 16.07.2026: 185.199.110.133 висел, 185.199.111.133 отдавал за 5 мс).
# --retry сам переберёт адреса; -f не даст HTML-странице ошибки уехать в sh.
_fetch() { curl -fsSL --connect-timeout 10 --max-time 120 --retry 2 "$1"; }
run_xkeen_installer() {
  info "--- Установка XKeen ---"
  command -v curl >/dev/null 2>&1 || { info "Ставлю curl (нужен установщику XKeen)..."; opkg install curl >/dev/null 2>&1; }
  command -v curl >/dev/null 2>&1 || { err "curl не установился — установщик XKeen не скачать."; return 1; }
  if [ ! -e "$TTY" ]; then
    warn "Нет терминала (/dev/tty) — не могу запустить интерактивный установщик."
    warn "Запусти вручную:"
    printf '  cd /tmp && sh -c "$(curl -sSL %s)"\n' "$XKEEN_GH"
    return 1
  fi

  # Качаем СРАЗУ, без предварительной проверки --spider: проверка отдельным
  # запросом ничего не гарантирует (следующий запрос уйдёт на другой IP), а её
  # зависание не даёт сработать фолбэку на зеркало. Фолбэк — по ОТКАЗУ скачивания.
  _installer=/tmp/xkeen-install.sh
  _src="$XKEEN_GH"
  info "Качаю установщик XKeen с GitHub..."
  if _fetch "$XKEEN_GH" > "$_installer" 2>/dev/null && [ -s "$_installer" ]; then
    ok "Установщик получен с GitHub."
  else
    warn "GitHub недоступен — переключаюсь на зеркало jsDelivr."
    _src="$XKEEN_CDN"
    if _fetch "$XKEEN_CDN" > "$_installer" 2>/dev/null && [ -s "$_installer" ]; then
      ok "Установщик получен с jsDelivr."
    else
      rm -f "$_installer"
      err "Не удалось скачать установщик XKeen ни с GitHub, ни с jsDelivr."
      warn "Проверь интернет на роутере и попробуй вручную:"
      printf '  cd /tmp && sh -c "$(curl -sSL %s)"\n' "$XKEEN_GH"
      return 1
    fi
  fi

  info "Запускаю установщик XKeen (интерактивный — ответь на его вопросы)..."
  echo
  # ввод/вывод установщика привязываем к терминалу
  ( cd /tmp && sh "$_installer" ) < "$TTY" > "$TTY" 2>&1
  _rc=$?
  rm -f "$_installer"
  echo
  if [ "$_rc" -eq 0 ]; then
    ok "Установщик XKeen завершился."
  else
    warn "Установщик XKeen вернул код $_rc. Если что-то пошло не так — запусти вручную:"
    printf '  cd /tmp && sh -c "$(curl -sSL %s)"\n' "$_src"
  fi
}
# ----------------------------------------------------------------------------
# DROPBEAR — фикс протухшего pid-файла (SSH на 222 не поднимается после ребута)
#
# Штатный S51dropbear из Entware считает демон живым по формуле
#   [ -f $PIDFILE ] && [ -d /proc/`cat $PIDFILE` ]
# то есть проверяет только СУЩЕСТВОВАНИЕ каталога /proc/<PID>, не сверяя, ЧЕЙ
# это процесс. Сам pid-файл лежит на ext4 флешки и переживает перезагрузку.
# После ребута его номер занимает другой процесс (на этом железе — tsmb-server,
# встроенный SMB Keenetic), скрипт решает «уже запущен», молча выходит — и на
# порту 222 никто не слушает. Ребут не лечит: pid-файл каждый раз тот же.
# Лечение: сверять /proc/<PID>/comm и удалять протухший pid-файл перед стартом.
# ----------------------------------------------------------------------------
fix_dropbear() {
  echo
  info "--- Фикс SSH-222: протухший pid-файл dropbear ---"
  DB_INIT="/opt/etc/init.d/S51dropbear"
  if ! opkg list-installed 2>/dev/null | grep -q '^dropbear '; then
    warn "Пакет dropbear не установлен — фикс не нужен."
    return 1
  fi
  if [ ! -f "$DB_INIT" ]; then
    warn "Не найден $DB_INIT — пропускаю."
    return 1
  fi
  if grep -q '/proc/\$pid/comm' "$DB_INIT" 2>/dev/null; then
    ok "Фикс уже накатан ранее."
    return 0
  fi
  if [ ! -f "${DB_INIT}.bak" ]; then
    cp "$DB_INIT" "${DB_INIT}.bak" && info "Оригинал сохранён: ${DB_INIT}.bak"
  fi
  cat > "$DB_INIT" << 'DBEOF'
#!/bin/sh

PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin

DROPBEAR="/opt/sbin/dropbear"

. /opt/etc/config/dropbear.conf

PIDFILE="${PIDFILE:-/opt/var/run/dropbear.pid}"

# Демон считается живым, только если PID из pid-файла реально принадлежит
# процессу dropbear. Раньше проверялось лишь наличие /proc/<PID>, из-за чего
# после ребута чужой процесс, занявший тот же PID, выдавался за живой dropbear.
dropbear_status ()
{
  pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [ -n "$pid" ] || return 1
  [ -d "/proc/$pid" ] || return 1
  case "$(cat "/proc/$pid/comm" 2>/dev/null)" in
    dropbear) return 0 ;;
    *)        return 1 ;;
  esac
}

start()
{
  # подчищаем протухший pid-файл, оставшийся от прошлой загрузки
  if [ -f "$PIDFILE" ] && ! dropbear_status
  then
    rm -f "$PIDFILE"
  fi
  $DROPBEAR -p $PORT -P $PIDFILE
}

stop()
{
  kill `cat $PIDFILE`
  rm -f "$PIDFILE"
}
case "$1" in
  start)
    if dropbear_status
    then
      echo dropbear already running
    else
      start
    fi
    ;;
  stop)
    if dropbear_status
    then
      stop
    else
      echo dropbear is not running
      rm -f "$PIDFILE"
    fi
    ;;
  status)
    if dropbear_status
    then
      echo dropbear already running
    else
      echo dropbear is not running
    fi
    ;;
  restart)
    stop
    sleep 3
    start
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    ;;
esac
DBEOF
  chmod +x "$DB_INIT"
  if sh -n "$DB_INIT" 2>/dev/null; then
    ok "S51dropbear пропатчен (проверка /proc/PID/comm + очистка протухшего pid)."
  else
    warn "Синтаксическая ошибка в новом $DB_INIT — откатываю."
    [ -f "${DB_INIT}.bak" ] && cp "${DB_INIT}.bak" "$DB_INIT"
    return 1
  fi
  # если демон сейчас не слушает 222 — поднимаем
  if "$DB_INIT" status 2>/dev/null | grep -q 'not running'; then
    info "Запускаю dropbear..."
    "$DB_INIT" start >/dev/null 2>&1
  fi
  if netstat -tln 2>/dev/null | grep -q ':222 '; then
    ok "SSH слушает порт 222."
  else
    warn "Порт 222 не слушается. Проверь: $DB_INIT start"
  fi
  warn "Учти: opkg upgrade dropbear затирает патч — прогони этот пункт заново."
  return 0
}
# ----------------------------------------------------------------------------
# SWAP — диагностика + включение (человекочитаемо)
# ----------------------------------------------------------------------------
find_swap() { blkid 2>/dev/null | grep 'LABEL="SWAP"' | cut -d: -f1 | head -n1; }
swap_size_mb() { # размер включённого swap в МБ по /proc/swaps (аргумент — устройство)
  _dev="$1"
  awk -v d="$_dev" '$1==d { printf "%d", $3/1024 }' /proc/swaps 2>/dev/null
}
setup_swap() {
  echo
  info "--- Swap: проверка и включение ---"
  # /opt — чтобы при необходимости угадать swap-раздел на том же диске
  OPT_DEV="$(grep ' /opt ' /proc/mounts 2>/dev/null | awk '{print $1}' | head -n1)"
  SWAP_DEV="$(find_swap)"
  if [ -n "$SWAP_DEV" ]; then
    ok "Раздел найден по метке SWAP: $SWAP_DEV"
    # Уже активен? Тогда сигнатура заведомо на месте — mkswap не трогаем.
    if grep -q "^$SWAP_DEV " /proc/swaps 2>/dev/null; then
      ok "Swap-сигнатура на месте (раздел уже активен)."
    else
      # Не активен — пробуем включить как есть; если не вышло, создаём сигнатуру.
      swapon "$SWAP_DEV" 2>/dev/null
      if grep -q "^$SWAP_DEV " /proc/swaps 2>/dev/null; then
        ok "Swap-сигнатура на месте."
      else
        info "Swap не включается — создаю сигнатуру (mkswap)..."
        if mkswap -L SWAP "$SWAP_DEV" >/dev/null 2>&1; then
          ok "Сигнатура создана."
        else
          warn "Не удалось создать swap-сигнатуру на $SWAP_DEV."
        fi
      fi
    fi
  else
    warn "Раздел с меткой SWAP не найден — ищу по разметке..."
    if [ -n "$OPT_DEV" ]; then
      GUESS="$(echo "$OPT_DEV" | sed 's/2$/1/')"   # sdX2 -> sdX1
      if [ -b "$GUESS" ]; then
        info "Похоже на swap-раздел: $GUESS — ставлю метку SWAP и сигнатуру..."
        if mkswap -L SWAP "$GUESS" >/dev/null 2>&1; then
          SWAP_DEV="$GUESS"
          ok "Метка и сигнатура поставлены: $SWAP_DEV"
        else
          warn "Не удалось разметить $GUESS как swap."
        fi
      else
        warn "Подходящий раздел ($GUESS) не найден."
      fi
    else
      warn "Не удалось определить диск /opt — swap не настроить автоматически."
    fi
  fi
  if [ -z "$SWAP_DEV" ]; then
    warn "SWAP выключен: раздел не найден. (Флешка сделана без swap-раздела?)"
    return 1
  fi
  # включаем (если ещё не включён)
  if grep -q "^$SWAP_DEV " /proc/swaps 2>/dev/null; then
    ok "SWAP включён ($(swap_size_mb "$SWAP_DEV") МБ): $SWAP_DEV"
  else
    swapon "$SWAP_DEV" 2>/dev/null
    if grep -q "^$SWAP_DEV " /proc/swaps 2>/dev/null; then
      ok "SWAP включён ($(swap_size_mb "$SWAP_DEV") МБ): $SWAP_DEV"
    else
      warn "SWAP не включился ($SWAP_DEV). Проверь вручную: swapon $SWAP_DEV"
    fi
  fi
  # автозапуск при загрузке (поиск по метке — устойчиво к смене буквы диска)
  cat > /opt/etc/init.d/S02swap << 'SWAPEOF'
#!/bin/sh
# Активация swap по метке SWAP (без findfs/fstab, устойчиво к смене буквы диска)
find_swap() { blkid | grep 'LABEL="SWAP"' | cut -d: -f1 | head -n1; }
case "$1" in
  start)
    DEV="$(find_swap)"
    [ -z "$DEV" ] && { echo "swap: раздел с меткой SWAP не найден"; exit 1; }
    swapon "$DEV" 2>/dev/null && echo "swap on: $DEV" || echo "swap уже включён: $DEV"
    ;;
  stop)
    DEV="$(find_swap)"
    [ -n "$DEV" ] && swapoff "$DEV" 2>/dev/null && echo "swap off: $DEV"
    ;;
  *) echo "usage: $0 {start|stop}" ;;
esac
SWAPEOF
  chmod +x /opt/etc/init.d/S02swap
  ok "Автозапуск swap настроен: /opt/etc/init.d/S02swap"
  return 0
}
# ----------------------------------------------------------------------------
# Пакеты + компоненты + пароль (полная настройка)
# ----------------------------------------------------------------------------
setup_packages() {
  echo
  info "--- Обновление opkg и базовые пакеты ---"
  opkg update || warn "opkg update завершился с ошибкой (проверь интернет на роутере)."
  info "opkg upgrade (может занять время)..."
  opkg upgrade 2>/dev/null || warn "opkg upgrade завершился с предупреждениями."
  # ca-bundle/ca-certificates — для HTTPS; curl и tar — требования установщика XKeen;
  # nano/vim — редакторы конфигов.
  for pkg in ca-bundle ca-certificates curl tar nano vim; do
    if opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
      ok "$pkg уже установлен."
    else
      info "Устанавливаю $pkg..."
      opkg install "$pkg" >/dev/null 2>&1 && ok "$pkg установлен." || warn "Не удалось установить $pkg."
    fi
  done
}
check_components() {
  echo
  info "--- Компоненты Keenetic (для XKeen) ---"
  # Эти компоненты ставятся в ВЕБ-интерфейсе роутера, из shell не поставить — только проверяем.
  NF_OK=0
  if [ -d /proc/sys/net/netfilter ] || lsmod 2>/dev/null | grep -q nf_; then
    NF_OK=1
  fi
  if [ "$NF_OK" = 1 ]; then
    ok "Netfilter-модули присутствуют."
  else
    warn "Netfilter не обнаружен. Включи в вебе: Общие настройки -> компонент «Модули ядра подсистемы Netfilter»."
  fi
  if [ -d /proc/sys/net/ipv6 ]; then
    ok "IPv6 включён в ядре."
  else
    warn "IPv6 не обнаружен. Для XKeen включи IPv6 в вебе (если требуется твоей конфигурацией)."
  fi
  # ВАЖНО: встроенный SSH Keenetic (порт 22) НЕ отключать — это единственный
  # путь на роутер, если Entware-овый dropbear на 222 не поднялся. Логин —
  # пользователь из веб-панели (обычно admin), затем в CLI: exec sh
  info "Встроенный SSH Keenetic (порт 22) оставь включённым — это аварийный доступ."
  info "Вход: ssh -p 22 <юзер_из_вебки>@<ip_роутера>, далее в CLI команда: exec sh"
}
offer_password_change() {
  echo
  info "--- Безопасность: пароль SSH (dropbear) ---"
  warn "Пароль по умолчанию 'keenetic' небезопасен. Рекомендуется сменить."
  ANS="$(ask "Сменить пароль root сейчас? [y/N]: ")"
  case "$ANS" in
    y|Y|yes|Yes)
      if [ -e "$TTY" ]; then
        passwd root < "$TTY" > "$TTY" 2>&1 && ok "Пароль изменён." || warn "Смена пароля не удалась."
      else
        warn "Нет терминала — смени вручную командой: passwd root"
      fi
      ;;
    *)
      info "Пропущено. Сменить позже: passwd root"
      ;;
  esac
}
# ----------------------------------------------------------------------------
# Сценарии меню
# ----------------------------------------------------------------------------
mode_full() {
  setup_swap
  setup_packages
  check_components
  fix_dropbear
  offer_password_change
  run_xkeen_installer
  echo
  ok "Полная настройка завершена. Рекомендуется перезагрузить роутер: reboot"
}
mode_xkeen_only() {
  run_xkeen_installer
  echo
  ok "Готово. Если XKeen установлен впервые — рекомендуется reboot."
}
mode_swap_only() {
  if setup_swap; then
    echo
    ok "Swap готов. Текущее состояние (/proc/swaps):"
    # заголовок + строки со swap-разделами (тип 'partition'/'file'), без слова 'swap'
    head -n1 /proc/swaps 2>/dev/null
    grep -v '^Filename' /proc/swaps 2>/dev/null || warn "swap не активен."
  fi
}
mode_dropbear_only() {
  fix_dropbear
}
# ----------------------------------------------------------------------------
# Точка входа
# ----------------------------------------------------------------------------
echo
info "=== router-setup: настройка Entware + XKeen ==="
echo
# Проверки окружения
[ -d /opt ] || die "Каталог /opt не найден. Entware не установлен?"
command -v opkg >/dev/null 2>&1 || die "opkg не найден. Сначала установи Entware."
ARCH="$(opkg print-architecture 2>/dev/null | grep -v '^arch all' | awk '{print $2}' | head -n1)"
[ -n "$ARCH" ] && ok "Entware на месте, арка: $ARCH" || ok "Entware на месте."
echo
printf '%sЧто делаем?%s\n' "$C_C" "$C_0"
echo "  1) Полная настройка (swap + пакеты + vim) и установка XKeen"
echo "  2) Только установка XKeen (GitHub, при сбое — jsDelivr)"
echo "  3) Только swap (после восстановления флешки из бэкапа)"
echo "  4) Только фикс SSH-222 (протухший pid-файл dropbear)"
echo "  q) Выход"
CHOICE="$(ask "Номер (1/2/3/4/q): ")"
case "$CHOICE" in
  1) mode_full ;;
  2) mode_xkeen_only ;;
  3) mode_swap_only ;;
  4) mode_dropbear_only ;;
  q|Q|"") info "Выход." ; exit 0 ;;
  *) die "Некорректный выбор: $CHOICE" ;;
esac
