#!/bin/sh
#
# router-setup.sh — пост-установочная настройка роутера Keenetic/Netcraze под Entware + XKeen
# Запуск НА РОУТЕРЕ (после установки Entware), по SSH (порт 222).
#
# ВАЖНО: на чистом Entware нет ни curl, ни HTTPS-wget, поэтому сначала ставим
# wget-ssl, и только потом качаем этот скрипт. Две команды:
#
#   opkg update && opkg install wget-ssl ca-bundle ca-certificates
#   wget -qO- https://raw.githubusercontent.com/lastik9/keenetic-entware/main/router-setup.sh | sh
#
#
# Делает:
#   1. Проверки окружения (Entware, /opt, swap-раздел)
#   2. Swap: mkswap -L SWAP + автозапуск S02swap (поиск по метке через blkid)
#   3. opkg update + базовые пакеты (nano, curl, ca-bundle, ca-certificates)
#   4. Проверка компонентов Keenetic (netfilter/IPv6) — с подсказкой, что включить в вебе
#   5. Предложение сменить SSH-пароль root (dropbear)
#   6. Печать официальной команды установки XKeen
#
# ВНИМАНИЕ: первый черновик, обкатывать на живом роутере.
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

# Интерактивный ввод под `curl | sh`: читаем с терминала
TTY=/dev/tty
ask() { # ask "вопрос" -> ответ в stdout; пусто если нет tty
  _q="$1"
  if [ -e "$TTY" ]; then
    printf '%s' "$_q" > "$TTY"
    read _a < "$TTY"
    printf '%s' "$_a"
  fi
}

echo
info "=== router-setup: настройка Entware + подготовка под XKeen ==="
echo

# ----------------------------------------------------------------------------
# 1. Проверки окружения
# ----------------------------------------------------------------------------
[ -d /opt ] || die "Каталог /opt не найден. Entware не установлен?"
command -v opkg >/dev/null 2>&1 || die "opkg не найден. Сначала установи Entware."

ARCH="$(opkg print-architecture 2>/dev/null | grep -v '^arch all' | awk '{print $2}' | head -n1)"
[ -n "$ARCH" ] && ok "Entware на месте, арка: $ARCH" || ok "Entware на месте."

# ext4-раздел /opt
OPT_DEV="$(grep ' /opt ' /proc/mounts | awk '{print $1}' | head -n1)"
[ -n "$OPT_DEV" ] && info "/opt смонтирован с: $OPT_DEV"

# ----------------------------------------------------------------------------
# 2. Swap
# ----------------------------------------------------------------------------
echo
info "--- Swap ---"

find_swap() { blkid 2>/dev/null | grep 'LABEL="SWAP"' | cut -d: -f1 | head -n1; }

SWAP_DEV="$(find_swap)"

if [ -z "$SWAP_DEV" ]; then
  # метки SWAP нет — попробуем найти swap-раздел как первый раздел диска с /opt
  warn "Раздел с меткой SWAP не найден."
  # Угадываем: тот же диск, что и /opt, но раздел 1 (sdX1)
  if [ -n "$OPT_DEV" ]; then
    GUESS="$(echo "$OPT_DEV" | sed 's/2$/1/')"   # sdX2 -> sdX1
    if [ -b "$GUESS" ]; then
      info "Похоже, swap-раздел: $GUESS — ставлю метку SWAP и сигнатуру..."
      mkswap -L SWAP "$GUESS" && SWAP_DEV="$GUESS"
    fi
  fi
else
  info "Найден swap-раздел по метке: $SWAP_DEV"
  # убедимся, что на нём есть swap-сигнатура (если метка есть, но не форматирован)
  if ! blkid "$SWAP_DEV" 2>/dev/null | grep -q 'TYPE="swap"'; then
    info "Ставлю swap-сигнатуру на $SWAP_DEV..."
    mkswap -L SWAP "$SWAP_DEV"
  fi
fi

if [ -n "$SWAP_DEV" ]; then
  swapon "$SWAP_DEV" 2>/dev/null
  if grep -q "$(basename "$SWAP_DEV")" /proc/swaps 2>/dev/null; then
    ok "Swap активен: $SWAP_DEV"
  else
    warn "Swap не активировался (возможно уже включён)."
  fi

  # автозапуск S02swap (поиск по метке через blkid)
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
  ok "Автозапуск swap установлен: /opt/etc/init.d/S02swap"
else
  warn "Swap-раздел не найден — пропускаю. (Флешка сделана без swap-раздела?)"
fi

# ----------------------------------------------------------------------------
# 3. opkg update + базовые пакеты
# ----------------------------------------------------------------------------
echo
info "--- Обновление opkg и базовые пакеты ---"
opkg update || warn "opkg update завершился с ошибкой (проверь интернет на роутере)."
info "opkg upgrade (может занять время)..."
opkg upgrade 2>/dev/null || warn "opkg upgrade завершился с предупреждениями."

# ca-bundle/ca-certificates — для HTTPS; curl и tar — требования установщика XKeen; nano — правка конфигов
for pkg in ca-bundle ca-certificates curl tar nano; do
  if opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
    ok "$pkg уже установлен."
  else
    info "Устанавливаю $pkg..."
    opkg install "$pkg" >/dev/null 2>&1 && ok "$pkg установлен." || warn "Не удалось установить $pkg."
  fi
done

# ----------------------------------------------------------------------------
# 4. Проверка компонентов Keenetic (netfilter / IPv6)
# ----------------------------------------------------------------------------
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

warn "Также в вебе: отключи встроенный SSH-сервер Keenetic, если XKeen/Entware используют свой (порт 222)."

# ----------------------------------------------------------------------------
# 5. Смена SSH-пароля root (dropbear)
# ----------------------------------------------------------------------------
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

# ----------------------------------------------------------------------------
# 6. Установка XKeen — печатаем официальную команду (ставит пользователь сам)
# ----------------------------------------------------------------------------
echo
info "--- XKeen ---"
ok "Система готова к установке XKeen."
echo
echo "${C_C}Запусти установщик XKeen вручную (интерактивный — спросит про ядро и конфиги):${C_0}"
echo
echo "  cd /tmp && sh -c \"\$(curl -sSL https://raw.githubusercontent.com/jameszeroX/XKeen/main/install.sh)\""
echo
echo "${C_Y}Если GitHub недоступен — тот же установщик через CDN jsDelivr:${C_0}"
echo "  cd /tmp && sh -c \"\$(curl -sSL https://cdn.jsdelivr.net/gh/jameszeroX/XKeen@main/install.sh)\""
echo
echo "  Документация и настройка Xray: https://github.com/jameszeroX/XKeen"
echo
ok "Готово. Рекомендуется перезагрузить роутер: reboot"
