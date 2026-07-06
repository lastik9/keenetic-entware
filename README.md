# keenetic-entware

**Русский** · [English](README.en.md)

Подготовка USB-флешки под **Entware** для роутеров **Keenetic / Netcraze** — одной командой, на «голом» маке, без Homebrew, Docker и сторонних программ разметки.

Скрипт размечает флешку (swap + ext4), форматирует ext4, кладёт на неё установщик нужной архитектуры и сам проверяет результат. Дальше остаётся вставить флешку в роутер и включить OPKG.

## Зачем

macOS не умеет создавать ext4 своими средствами. Обычные инструкции требуют ставить Paragon/сторонние программы или запускать Docker. Здесь всё делается одной командой: скрипт скачивает самодостаточные `mke2fs`/`debugfs` (universal, зависят только от `libSystem`), так что **на маке ничего ставить не нужно**.

## Требования

- macOS (Apple Silicon или Intel)
- USB-флешка (**всё содержимое будет стёрто**)
- Интернет на маке (скачать установщик) и на роутере (установить пакеты Entware)

Homebrew **не нужен**. Если `e2fsprogs` из Homebrew уже стоит — скрипт возьмёт его; если нет — скачает готовые universal-бинарники из Releases.

## Использование

Запусти в Терминале:

```
bash <(curl -fsSL https://raw.githubusercontent.com/lastik9/keenetic-entware/main/prepare.sh)
```

Скрипт:
1. Покажет **только съёмные** накопители и попросит выбрать нужный (с подтверждением вводом имени — чтобы нельзя было стереть не тот диск).
2. Спросит архитектуру процессора роутера (с подсказкой по моделям).
3. Разметит, отформатирует ext4, запишет установщик и проверит результат.

### Холостой прогон (ничего не пишется)

Посмотреть, что именно будет сделано, не трогая диск:

```
DRY_RUN=1 bash <(curl -fsSL https://raw.githubusercontent.com/lastik9/keenetic-entware/main/prepare.sh)
```

### Принудительно путь «голого мака» (игнорировать Homebrew)

```
IGNORE_BREW=1 bash <(curl -fsSL https://raw.githubusercontent.com/lastik9/keenetic-entware/main/prepare.sh)
```

## Соответствие архитектур

| Архив | Модели Keenetic / Netcraze |
|---|---|
| **mipsel** | Giga (KN-1010/1011), Ultra (KN-1810), Extra (KN-1710/1711/1713), Omni (KN-1410), Viva (KN-1910/1912/1913), Giant (KN-2610), Hero 4G (KN-2310/2311), Hopper (KN-3810), 4G (KN-1212); Zyxel Keenetic II/III, Extra, Giga II/III, Omni, Viva, Ultra и подобные |
| **mips** | Ultra SE (KN-2510), Giga SE (KN-2410), DSL (KN-2010), Skipper DSL (KN-2112), Duo (KN-2110), Hopper DSL (KN-3610); Zyxel Keenetic DSL, LTE, VOX |
| **aarch64** | Peak (KN-2710), Ultra (KN-1811 / NC-1812), Giga (KN-1012), Hopper (KN-3811), Hopper SE (KN-3812) |

Если не уверен — посмотри модель на наклейке или в веб-интерфейсе роутера.

## На роутере

После того как флешка готова:

1. Вставь флешку в Keenetic.
2. Веб-интерфейс → **Общие настройки** → включи компоненты **«Поддержка открытых пакетов (OPKG)»** и **«Файловая система Ext»**.
3. Открой страницу **OPKG** → выбери накопитель **OPKG** → **Сохранить**. Роутер распакует установщик и докачает пакеты Entware с `bin.entware.net` (роутеру нужен интернет).
4. Смотри **Системный журнал** (Диагностика) — там появятся строки об успешной установке Entware.

### Активация swap

Скрипт резервирует swap-раздел на 1 ГБ, но саму активацию оставляет роутеру (там — правильное место для `mkswap`). По SSH (логин `root`, порт `222` после установки Entware):

```
mkswap /dev/sda1
```

Затем создай init-скрипт, чтобы swap поднимался при каждой загрузке:

```
cat > /opt/etc/init.d/S02swap << 'EOF'
#!/bin/sh
case "$1" in
  start) swapoff /dev/sda1 2>/dev/null; swapon /dev/sda1 2>/dev/null ;;
  stop)  swapoff /dev/sda1 2>/dev/null ;;
  *)     echo "usage: $0 {start|stop}" ;;
esac
EOF
chmod +x /opt/etc/init.d/S02swap
/opt/etc/init.d/S02swap start
```

Проверь командой `free` — в строке `Swap:` должно быть ~1 ГБ.

## Как это работает

- Разметка — встроенным `diskutil`; типы разделов (0x82 swap, 0x83 Linux) выставляются встроенным `fdisk`.
- ext4 создаётся через `mke2fs`, а установщик пишется в ext4-раздел через `debugfs` — **без монтирования** (macOS не умеет монтировать ext4, и это не требуется).
- Бинарники `mke2fs`/`debugfs` собраны из e2fsprogs как **universal** (arm64 + x86_64), внутренние либы влинкованы статически, поэтому зависят только от `/usr/lib/libSystem`. Как пересобрать самому — см. [BUILD.md](BUILD.md).

## Собрать бинарники самому

См. [BUILD.md](BUILD.md). Коротко: `bash build-macos-e2fsprogs.sh` скачает исходники e2fsprogs, соберёт universal-бандл, проверит его и напечатает SHA-256.

## Безопасность

- В списке — **только съёмные** накопители, системный диск выбрать нельзя.
- Перед стиранием нужно вручную ввести точное имя устройства для подтверждения.
- Скачанный бандл бинарников проверяется по зафиксированному SHA-256.

## Благодарности

- [Entware](https://github.com/Entware/Entware) — система пакетов, под которую готовится флешка.
- [e2fsprogs](https://github.com/tytso/e2fsprogs), Theodore Ts'o — `mke2fs` / `debugfs`.
- Инструкции сообщества: [Corvus-Malus/XKeen](https://github.com/Corvus-Malus/XKeen) и [MaxXxaM/keenetic-entware-flash](https://github.com/MaxXxaM/keenetic-entware-flash).

## Лицензия

MIT (скрипты этого проекта). Прилагаемые бинарники e2fsprogs распространяются под GPL-2.0 — см. [BUILD.md](BUILD.md).
