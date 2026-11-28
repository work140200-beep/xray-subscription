#!/bin/bash
# ============================================================
#  Установщик нового оформления меню Xray / Hysteria2.
#  Запуск:  sudo bash install-xray-menu-theme.sh
#  Меняет только /usr/local/bin/xray-menu — конфиги, ключи,
#  пользователи и подписки не затрагиваются.
# ============================================================
set -u

TARGET="/usr/local/bin/xray-menu"
BACKUP="${TARGET}.bak.$(date +%Y%m%d%H%M%S)"

if [[ "$EUID" -ne 0 ]]; then
    echo "Нужны root-права: sudo bash $0" >&2
    exit 1
fi

TMP=$(mktemp) || exit 1

cat > "$TMP" << 'XRAY_MENU_EOF'
#!/bin/bash
# ============================================================
#  Меню управления Xray / Hysteria2
#  Номера пунктов 1..15 не изменились — только визуальное
#  оформление: жирный шрифт, яркие цвета, ровные колонки.
# ============================================================

if [[ -t 1 ]]; then
    R=$'\033[0m'      # сброс
    B=$'\033[1m'      # жирный
    D=$'\033[2m'      # приглушённый
    CY=$'\033[1;36m'  # яркий циан
    GR=$'\033[1;32m'  # яркий зелёный
    YE=$'\033[1;33m'  # яркий жёлтый
    RE=$'\033[1;31m'  # яркий красный
else
    R=''; B=''; D=''; CY=''; GR=''; YE=''; RE=''
fi

rule()     { printf '%s' "${D}"; printf '─%.0s' {1..64}; printf '%s\n' "$R"; }
section()  { printf '\n%s▌  %s%s\n' "${B}${YE}" "$1" "$R"; }
item()     { printf '  %s%2s)%s  %s%-16s%s %s\n' "${B}${GR}" "$1" "$R" "${B}" "$2" "$R" "$3"; }

banner() {
    local art bl addr xstate hstate
    rule
    if command -v figlet >/dev/null 2>&1; then
        art=$(figlet -w 76 "XRAY" 2>/dev/null)
    fi
    if [[ -n "${art:-}" ]]; then
        while IFS= read -r bl; do printf '%s%s%s\n' "$CY" "$bl" "$R"; done <<< "$art"
    else
        printf '%s\n' "${B}${CY}   ██  XRAY / HYSTERIA2  —  ЦЕНТР УПРАВЛЕНИЯ  ██${R}"
    fi
    rule
    addr=$(head -n1 /usr/local/etc/xray/server-address 2>/dev/null || echo '—')
    if systemctl is-active --quiet xray 2>/dev/null; then xstate="${GR}ON$R"; else xstate="${RE}OFF$R"; fi
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then hstate="${GR}ON$R"; else hstate="${RE}OFF$R"; fi
    printf '  %sАдрес:%s %s   %sXray:%s %s   %sHysteria2:%s %s\n' \
        "$B" "$R" "$addr" "$B" "$R" "$xstate" "$B" "$R" "$hstate"
    rule
}

while true; do
    banner

    section 'ПОЛЬЗОВАТЕЛИ И ССЫЛКИ'
    item 1  mainuser        'ссылка основного пользователя'
    item 2  newuser         'создать пользователя'
    item 3  rmuser          'удалить пользователя'
    item 4  userlist        'список пользователей'
    item 5  sharelink       'ссылка для существующего пользователя'

    section 'МАСКИРОВКА, МАРШРУТИЗАЦИЯ, ГЕО'
    item 6  setcascade      'настроить каскад (proxy chaining)'
    item 7  unsetcascade    'отключить каскад'
    item 8  setmask         'изменить маскировку (SNI/shortId/fp)'
    item 9  routingmode     'RU напрямую, остальное — в туннель'
    item 10 disable_routing 'отключить маршрутизацию (весь трафик напрямую)'
    item 11 renewgeo        'обновить geo-базы'

    section 'ПОДПИСКИ'
    item 12 subscription    'управление подписками'
    item 13 setsubdomain    'настроить/сменить домен подписок'

    section 'ДИАГНОСТИКА'
    item 14 xray-check      'служба, порты, ключи, ссылки'
    item 15 hy2restart      'пересобрать конфиг и перезапустить Hysteria2'

    printf '\n'
    printf '%s' "${B}${CY}  Ваш выбор [0 — выход]: ${R}"
    read -r choice

    case "$choice" in
      1)  mainuser ;;
      2)  newuser ;;
      3)  rmuser ;;
      4)  userlist ;;
      5)  sharelink ;;
      6)  setcascade ;;
      7)  unsetcascade ;;
      8)  setmask ;;
      9)  routingmode ;;
      10) disable_routing ;;
      11) renewgeo ;;
      12) subscription ;;
      13) setsubdomain ;;
      14) xray-check ;;
      15) hy2restart ;;
      0)  printf '%s\n' "${GR}  Выход.${R}"; exit 0 ;;
      *)  printf '%s\n' "${RE}  Неизвестный пункт: ${choice}${R}" ;;
    esac
done
XRAY_MENU_EOF

# Если файл переносили через Windows, убираем CR из содержимого меню.
tr -d '\r' < "$TMP" > "${TMP}.clean" && mv "${TMP}.clean" "$TMP"

# Проверяем синтаксис ДО замены рабочего файла.
if ! bash -n "$TMP"; then
    echo "Ошибка: сгенерированное меню не прошло проверку bash -n. Старый файл не изменён." >&2
    rm -f "$TMP"
    exit 1
fi

if [[ -f "$TARGET" ]]; then
    cp -p "$TARGET" "$BACKUP"
    echo "Резервная копия старого меню: $BACKUP"
fi

install -m 755 "$TMP" "$TARGET" || { rm -f "$TMP"; exit 1; }
rm -f "$TMP"

echo ""
echo "Готово: $TARGET обновлён."
echo "Пункты 1..15 и все команды остались прежними."

if [[ -t 0 ]]; then
    read -rp "Запустить новое меню сейчас? [y/N]: " ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        exec "$TARGET"
    fi
fi