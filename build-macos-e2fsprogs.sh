#!/usr/bin/env bash
#
# build-macos-e2fsprogs.sh
# Собирает universal (arm64 + x86_64) mke2fs, debugfs и e2image из исходников e2fsprogs
# для проекта keenetic-entware-flash (путь «голого мака» без Homebrew).
#
# Итог: dist/e2fsprogs-macos-universal.tar.gz  (плоский: mke2fs, debugfs, e2image)
#       + печатает sha256 для вставки в prepare.sh.
#
# Запускать на macOS с установленными Xcode Command Line Tools.
#   bash build-macos-e2fsprogs.sh
#
set -euo pipefail

E2FS_VER="1.47.4"   # держим в паре с версией из brew ради идентичного поведения
SRC_NAME="e2fsprogs-${E2FS_VER}"
SRC_TGZ="${SRC_NAME}.tar.gz"
URL_PRIMARY="https://www.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v${E2FS_VER}/${SRC_TGZ}"
URL_FALLBACK="https://downloads.sourceforge.net/project/e2fsprogs/e2fsprogs/v${E2FS_VER}/${SRC_TGZ}"

ROOT="$(pwd)"
BUILD="$ROOT/build-e2fs"
DIST="$ROOT/dist"
BUNDLE="e2fsprogs-macos-universal.tar.gz"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
info(){ printf "%s[i]%s %s\n" "$c_cyn" "$c_rst" "$*"; }
ok(){ printf "%s[v]%s %s\n" "$c_grn" "$c_rst" "$*"; }
warn(){ printf "%s[!]%s %s\n" "$c_yel" "$c_rst" "$*"; }
die(){ printf "%s[x]%s %s\n" "$c_red" "$c_rst" "$*" >&2; exit 1; }

# ---- 0. Проверки окружения ----
[[ "$(uname -s)" == "Darwin" ]] || die "Только для macOS."
xcode-select -p >/dev/null 2>&1 || die "Нет Xcode Command Line Tools. Поставь: xcode-select --install"
command -v clang >/dev/null || die "clang не найден."
command -v make  >/dev/null || die "make не найден."
ok "Окружение готово (clang, make, CLT)."

# ---- 1. Исходники ----
mkdir -p "$BUILD"; cd "$BUILD"
if [[ ! -f "$SRC_TGZ" ]]; then
  info "Скачиваю $SRC_TGZ ..."
  curl -fL --retry 3 -o "$SRC_TGZ" "$URL_PRIMARY" \
    || curl -fL --retry 3 -o "$SRC_TGZ" "$URL_FALLBACK" \
    || die "Не удалось скачать исходники."
fi
rm -rf "$SRC_NAME"
tar -xzf "$SRC_TGZ"
ok "Исходники распакованы: $SRC_NAME"

# ---- 2. Конфигурируем на universal ----
# Приём: передаём обе арки прямо в CC. Тест-программы configure получаются
# universal и запускаются на нативной половине -> кросс-компиляция не мешает.
# На macOS e2fsprogs по умолчанию НЕ собирает shared-либы -> внутренние либы
# влинковываются статически, снаружи остаётся только libSystem.
cd "$SRC_NAME"
export CC="clang -arch arm64 -arch x86_64"
info "configure (universal, --disable-nls)..."
./configure --disable-nls >/tmp/e2fs-configure.log 2>&1 \
  || { tail -30 /tmp/e2fs-configure.log; die "configure упал (лог: /tmp/e2fs-configure.log)"; }
ok "configure ок."

# ---- 3. Собираем только нужное: библиотеки + mke2fs + debugfs + e2image ----
info "make libs ..."
make -j"$JOBS" libs >/tmp/e2fs-libs.log 2>&1 \
  || { tail -40 /tmp/e2fs-libs.log; die "make libs упал (лог: /tmp/e2fs-libs.log)"; }
info "make mke2fs ..."
make -j"$JOBS" -C misc mke2fs >/tmp/e2fs-mke2fs.log 2>&1 \
  || { tail -40 /tmp/e2fs-mke2fs.log; die "make mke2fs упал (лог: /tmp/e2fs-mke2fs.log)"; }
info "make debugfs ..."
make -j"$JOBS" -C debugfs debugfs >/tmp/e2fs-debugfs.log 2>&1 \
  || { tail -40 /tmp/e2fs-debugfs.log; die "make debugfs упал (лог: /tmp/e2fs-debugfs.log)"; }
info "make e2image ..."
make -j"$JOBS" -C misc e2image >/tmp/e2fs-e2image.log 2>&1 \
  || { tail -40 /tmp/e2fs-e2image.log; die "make e2image упал (лог: /tmp/e2fs-e2image.log)"; }
ok "Сборка завершена."

MKE2FS_BIN="$BUILD/$SRC_NAME/misc/mke2fs"
DEBUGFS_BIN="$BUILD/$SRC_NAME/debugfs/debugfs"
E2IMAGE_BIN="$BUILD/$SRC_NAME/misc/e2image"
[[ -f "$MKE2FS_BIN" ]] || die "Не найден собранный mke2fs."
[[ -f "$DEBUGFS_BIN" ]] || die "Не найден собранный debugfs."
[[ -f "$E2IMAGE_BIN" ]] || die "Не найден собранный e2image."

# ---- 4. Проверки: universal + только libSystem ----
check_bin() {
  local b="$1" name; name="$(basename "$b")"
  # universal?
  if file "$b" | grep -q "2 architectures"; then
    ok "$name: universal (arm64 + x86_64)."
  else
    warn "$name: НЕ universal! ($(file "$b"))"
  fi
  # внешние зависимости — только /usr/lib или /System?
  # Реальные зависимости в `otool -L` идут с отступом (таб); строки без отступа
  # (путь бинарника, заголовки архитектур) — не зависимости, их игнорируем.
  local bad
  bad="$(otool -L "$b" | grep -E '^[[:space:]]' | awk '{print $1}' \
        | grep -vE '^/usr/lib/|^/System/' || true)"
  if [[ -n "$bad" ]]; then
    warn "$name зависит от посторонних либ:"
    printf '      %s\n' $bad
    warn "Такой бинарник упадёт на маке без этих либ. Нужно разобраться."
  else
    ok "$name: внешние зависимости только системные (libSystem)."
  fi
}
echo; info "Проверяю бинарники..."
check_bin "$MKE2FS_BIN"
check_bin "$DEBUGFS_BIN"
check_bin "$E2IMAGE_BIN"

# ---- 5. Пакуем ----
echo; info "Пакую бандл..."
rm -rf "$DIST"; mkdir -p "$DIST/stage"
cp "$MKE2FS_BIN" "$DEBUGFS_BIN" "$E2IMAGE_BIN" "$DIST/stage/"
chmod +x "$DIST/stage/mke2fs" "$DIST/stage/debugfs" "$DIST/stage/e2image"
# ad-hoc подпись (prepare.sh делает это и сам, но пусть будет)
codesign --force -s - "$DIST/stage/mke2fs" "$DIST/stage/debugfs" "$DIST/stage/e2image" 2>/dev/null || \
  warn "codesign не прошёл (не критично, prepare.sh подпишет при скачивании)."
# плоский тарбол: mke2fs, debugfs, e2image в корне
tar -czf "$DIST/$BUNDLE" -C "$DIST/stage" mke2fs debugfs e2image
rm -rf "$DIST/stage"

SHA="$(shasum -a 256 "$DIST/$BUNDLE" | awk '{print $1}')"
echo
ok "Готово: $DIST/$BUNDLE"
echo
printf "%s─── Вставь это в prepare.sh ───%s\n" "$c_cyn" "$c_rst"
printf "E2FS_RELEASE_TAG=\"e2fsprogs-v%s-macos\"   # или свой тег\n" "$E2FS_VER"
printf "E2FS_BUNDLE_SHA256=\"%s\"\n" "$SHA"
echo
printf "%sДальше:%s залей %s в GitHub Releases под этим тегом,\n" "$c_cyn" "$c_rst" "$BUNDLE"
printf "        и пропиши E2FS_OWNER_REPO=\"твой_гитхаб/keenetic-entware-flash\".\n"
