#!/bin/bash
# =============================================================================
# Единый установщик и менеджер Xray-core: VLESS-TCP-Reality + VLESS-XHTTP-Reality
# + Hysteria2 (QUIC) отдельным сервисом.
# Пользователи создаются один раз и работают на всех транспортах
# (в Hysteria2 пароль каждого клиента = его UUID).
# Включает управление каскадом (proxy chaining) и маскировкой (SNI/fp/shortId).
# =============================================================================

set -u

CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"
SETTINGS="/usr/local/etc/xray/.settings"
SERVER_ADDRESS_FILE="/usr/local/etc/xray/server-address"
LIB="/usr/local/etc/xray/lib.sh"
SUBS_DIR="/usr/local/etc/xray/subscriptions"
SUBS_WEBROOT="/var/www/xray-subscriptions"
SUBS_DOMAIN_FILE="/usr/local/etc/xray/subscription-domain"
SUBS_SCHEME_FILE="/usr/local/etc/xray/subscription-scheme"

TCP_PORT="${TCP_PORT:-443}"
XHTTP_PORT="${XHTTP_PORT:-8443}"
HY2_PORT="${HY2_PORT:-443}"          # UDP/443 — выглядит как HTTP/3
MASK_DOMAIN="${MASK_DOMAIN:-}"       # ОБЯЗАТЕЛЬНО свой домен: github.com и др. блокируются хостерами
MASK_MODE="${MASK_MODE:-self}"       # self = свой серт/свой домен; external = чужой target
MASK_LOCAL_PORT="${MASK_LOCAL_PORT:-8444}"
XRAY_VERSION="${XRAY_VERSION:-v26.11.9}"
HY2_VERSION="${HY2_VERSION:-app/v2.14.0}"
HY2_OBFS="${HY2_OBFS:-no}"           # yes = salamander; ВСЕ клиенты должны указать obfs-password
DEFAULT_FP="${DEFAULT_FP:-chrome}"
SUBS_PORT="${SUBS_PORT:-9443}"
BACKUP_ROOT="/root/xray-manager-backups"
INSTALLER_BUILD="2026-11-28-acme-and-hash-fix"
# Адрес, который будет использоваться в клиентских VLESS-ссылках.
# Если SERVER_IP задан извне, он имеет приоритет; иначе адрес определяется локально.
SERVER_IP="${SERVER_IP:-}"

die() { echo "Ошибка: $1" >&2; exit 1; }

# Ранняя проверка прав: без root скрипт упадёт позже на mkdir/apt с кучей
# Permission denied. Проверяем сразу, до вопросов и до очистки старого.
if [[ "$EUID" -ne 0 ]]; then
    die "Нужны права root. Запустите: curl -sL https://raw.githubusercontent.com/work140200-beep/xray-subscription/main/xray-manager-subscription.sh -o /tmp/xray-manager-subscription.sh && sudo bash /tmp/xray-manager-subscription.sh"
fi

# Сохраняем значения предыдущей установки ДО очистки — они подставятся как
# значения по умолчанию в вопросах, чтобы повторный запуск не требовал ввода
# и не обрывался на пустом ответе.
OLD_MASK_DOMAIN=$(awk -F': ' '/^mask_domain/ {print $2}' "$SETTINGS" 2>/dev/null || true)
OLD_SUBS_DOMAIN=$(cat "$SUBS_DOMAIN_FILE" 2>/dev/null || true)
OLD_SERVER_IP=$(cat "$SERVER_ADDRESS_FILE" 2>/dev/null || true)

echo ""
echo "===== Очистка предыдущей установки (если была) ====="
# ВАЖНО: очистка выполняется ПЕРЕД всеми вопросами. Даже если пользователь
# прервёт ввод позже, старый VPN уже удалён и порты свободны.
# Скрипт можно запускать повторно на одном и том же сервере: перед установкой
# полностью удаляем всё, что могло остаться от предыдущего запуска (служба,
# конфиги, сгенерированные команды, nginx-сайт подписок), чтобы новый запуск
# не упирался в занятые порты или конфликтующие файлы. Делаем это ДО того, как
# скрипт начнёт заново писать что-либо в /usr/local/etc/xray.
if systemctl list-unit-files 2>/dev/null | grep -q '^xray\.service'; then
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    echo "Предыдущая служба xray остановлена."
fi

if [[ -f /etc/nginx/sites-enabled/xray-subscriptions || -f /etc/nginx/sites-available/xray-subscriptions ]]; then
    rm -f /etc/nginx/sites-enabled/xray-subscriptions /etc/nginx/sites-available/xray-subscriptions
    if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    fi
    echo "Предыдущий nginx-сайт подписок удалён."
fi

STAMP=$(date +%Y%m%d_%H%M%S)
BK="$BACKUP_ROOT/$STAMP"
mkdir -p "$BK"
for bk_path in /usr/local/etc/xray /etc/hysteria "$SUBS_WEBROOT" \
               /etc/nginx/sites-available/xray-subscriptions /etc/nginx/sites-available/xray-mask; do
    [[ -e "$bk_path" ]] && cp -a "$bk_path" "$BK/" 2>/dev/null || true
done
echo "Бэкап предыдущей установки: $BK"

rm -f /usr/local/bin/userlist /usr/local/bin/mainuser /usr/local/bin/newuser /usr/local/bin/rmuser \
      /usr/local/bin/sharelink /usr/local/bin/setcascade /usr/local/bin/unsetcascade /usr/local/bin/setmask \
      /usr/local/bin/routingmode /usr/local/bin/disable_routing /usr/local/bin/renewgeo \
      /usr/local/bin/subscription /usr/local/bin/setsubdomain /usr/local/bin/xray-check /usr/local/bin/xray-menu \
      /usr/local/bin/hy2sync /usr/local/bin/hy2restart /usr/local/bin/hysteria

if systemctl list-unit-files 2>/dev/null | grep -q '^hysteria-server\.service'; then
    systemctl stop hysteria-server 2>/dev/null || true
    systemctl disable hysteria-server 2>/dev/null || true
    rm -f /etc/systemd/system/hysteria-server.service
fi
rm -rf /etc/hysteria
rm -rf /usr/local/etc/xray
rm -rf "$SUBS_WEBROOT"

echo "Предыдущая конфигурация удалена. Устанавливаю всё заново."

validate_port() {
    local name="$1" val="$2"
    [[ "$val" =~ ^[0-9]+$ && "$val" -ge 1 && "$val" -le 65535 ]] || die "Некорректный порт для $name: '$val' (допустимо 1-65535)."
}

echo "BUILD=$INSTALLER_BUILD"
echo ""
echo "===== Порты протоколов ====="
read -rp "Порт для VLESS-TCP-Reality [Enter = $TCP_PORT]: " tcp_port_input
[[ -n "$tcp_port_input" ]] && TCP_PORT="$tcp_port_input"
validate_port "VLESS-TCP-Reality" "$TCP_PORT"

read -rp "Порт для VLESS-XHTTP-Reality [Enter = $XHTTP_PORT]: " xhttp_port_input
[[ -n "$xhttp_port_input" ]] && XHTTP_PORT="$xhttp_port_input"
validate_port "VLESS-XHTTP-Reality" "$XHTTP_PORT"

[[ "$TCP_PORT" != "$XHTTP_PORT" ]] || die "Порт VLESS-TCP-Reality и VLESS-XHTTP-Reality не должны совпадать ($TCP_PORT)."

echo ""
read -rp "Порт для Hysteria2 (UDP) [Enter = $HY2_PORT]: " hy2_port_input
[[ -n "$hy2_port_input" ]] && HY2_PORT="$hy2_port_input"
validate_port "Hysteria2" "$HY2_PORT"
echo "UDP-порт может совпадать с TCP-портом: это разные протоколы."

echo ""
echo "===== Маскировка Reality ====="
if [[ -z "$MASK_DOMAIN" && -n "$OLD_MASK_DOMAIN" ]]; then
    read -rp "Свой домен маскировки [Enter = $OLD_MASK_DOMAIN]: " MASK_DOMAIN
    [[ -z "$MASK_DOMAIN" ]] && MASK_DOMAIN="$OLD_MASK_DOMAIN"
elif [[ -z "$MASK_DOMAIN" ]]; then
    read -rp "Свой домен маскировки (Enter = адрес сервера, без LE-сертификата): " MASK_DOMAIN
fi
MASK_DOMAIN="${MASK_DOMAIN#.}"
if [[ -z "$MASK_DOMAIN" ]]; then
    MASK_DOMAIN="${OLD_SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    [[ -n "$MASK_DOMAIN" ]] || die "Не удалось определить домен маскировки."
    echo "Домен не указан — использую $MASK_DOMAIN (сертификат будет самоподписанным)."
fi
[[ "$MASK_DOMAIN" != *" "* ]] || die "Домен маскировки не должен содержать пробелы."
[[ "$MASK_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Некорректный домен маскировки: $MASK_DOMAIN"
DEFAULT_MASK_IP="${OLD_SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
for banned in github.com www.github.com google.com www.google.com cloudflare.com microsoft.com apple.com amazon.com; do
    if [[ "${MASK_DOMAIN,,}" == "$banned" ]]; then
        echo "ВНИМАНИЕ: домен $banned запрещён хостингом — заменяю на $DEFAULT_MASK_IP."
        MASK_DOMAIN="$DEFAULT_MASK_IP"
    fi
done
[[ "$MASK_MODE" == "self" || "$MASK_MODE" == "external" ]] || die "MASK_MODE должен быть self или external."
echo "Установка Xray: VLESS TCP-Reality (порт $TCP_PORT) + VLESS XHTTP-Reality (порт $XHTTP_PORT) + Hysteria2 (UDP $HY2_PORT)"
echo "Домен маскировки: $MASK_DOMAIN (режим: $MASK_MODE)"


echo ""
echo "===== Адрес сервера ====="
if [[ -z "$SERVER_IP" && -n "$OLD_SERVER_IP" ]]; then
    SERVER_IP="$OLD_SERVER_IP"
fi
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
fi
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
if [[ -n "$SERVER_IP" ]]; then
    echo "Локально определён адрес: $SERVER_IP"
    read -rp "IP/домен для клиентских ссылок [Enter = $SERVER_IP]: " server_input
    [[ -n "$server_input" ]] && SERVER_IP="$server_input"
else
    read -rp "IP/домен сервера для клиентских ссылок: " SERVER_IP
fi
SERVER_IP="${SERVER_IP#http://}"
SERVER_IP="${SERVER_IP#https://}"
SERVER_IP="${SERVER_IP%%/*}"
[[ -n "$SERVER_IP" && "$SERVER_IP" != *" "* ]] || die "Не удалось определить SERVER_IP."
mkdir -p /usr/local/etc/xray
printf '%s\n' "$SERVER_IP" > "$SERVER_ADDRESS_FILE"
echo "Адрес для клиентских ссылок: $SERVER_IP"

echo ""
echo "===== Настройка подписок ====="
echo "Укажите домен, который будет использоваться для ссылок подписки."
echo "Пример: sub.example.com"
if [[ -n "$OLD_SUBS_DOMAIN" ]]; then
    read -rp "Домен подписок [Enter = $OLD_SUBS_DOMAIN]: " SUBS_DOMAIN
    [[ -z "$SUBS_DOMAIN" ]] && SUBS_DOMAIN="$OLD_SUBS_DOMAIN"
else
    read -rp "Домен подписок (можно оставить пустым и настроить позже): " SUBS_DOMAIN
fi
SUBS_DOMAIN="${SUBS_DOMAIN#http://}"
SUBS_DOMAIN="${SUBS_DOMAIN#https://}"
SUBS_DOMAIN="${SUBS_DOMAIN%%/*}"
if [[ -n "$SUBS_DOMAIN" ]]; then
    [[ "$SUBS_DOMAIN" != *" "* ]] || die "Домен подписок не должен содержать пробелы."
    mkdir -p "$SUBS_DIR" "$SUBS_WEBROOT"
    printf '%s\n' "$SUBS_DOMAIN" > "$SUBS_DOMAIN_FILE"
    echo "Домен подписок: $SUBS_DOMAIN"
else
    echo "Домен подписок не указан. Настроить его позже можно командой setsubdomain (пункт 13 в xray-menu)."
fi

# ── 1. Подготовка системы ────────────────────────────────────────────────────
# На свежем VPS в первые минуты после старта система может сама фоном тянуть
# обновления безопасности (unattended-upgrades) и держать блокировку dpkg/apt.
# apt/apt-get сами умеют дожидаться освобождения этой блокировки без вмешательства
# извне — самодельная проверка через pgrep оказалась ненадёжной (ложно решала,
# что блокировка всё ещё держится, когда её уже не было), поэтому просто
# доверяем это самому apt, как и было изначально.
apt update || die "apt update завершился с ошибкой"
apt install -y qrencode curl jq wget openssl python3 iproute2 nginx certbot || die "Не удалось установить зависимости"

# ── 1.5 Маскировка под СВОЙ домен (self-steal SNI) ───────────────────────────
# Хостеры блокируют сторонние SNI (первый пример — github.com) на 443.
# В режиме self Reality зеркалирует локальный nginx с вашим сертификатом.
# ВАЖНО: неудача выпуска сертификата НЕ прерывает установку — меню и команды
# создаются в любом случае, а сертификат можно перевыпустить командой fixcert.
mkdir -p "$SUBS_WEBROOT"
MASK_CERT="/etc/letsencrypt/live/$MASK_DOMAIN/fullchain.pem"
MASK_KEY="/etc/letsencrypt/live/$MASK_DOMAIN/privkey.pem"
CERT_LOG="/var/log/xray-certbot.log"
CERT_OK=1
if [[ "$MASK_MODE" == "self" ]]; then
    if [[ ! -f "$MASK_CERT" || ! -f "$MASK_KEY" ]]; then
        # ACME-сайт нужен ВСЕГДА, даже когда домен маскировки совпадает с доменом
        # подписок: сайт подписок создаётся позже, а certbot обращается сейчас.
        cat > /etc/nginx/sites-available/xray-acme << NGINX_ACME_EOF
server {
    listen 80;
    listen [::]:80;
    server_name $MASK_DOMAIN ${SUBS_DOMAIN:-$MASK_DOMAIN};
    root $SUBS_WEBROOT;
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; default_type text/plain; }
    location / { return 404; }
}
NGINX_ACME_EOF
        ln -sf /etc/nginx/sites-available/xray-acme /etc/nginx/sites-enabled/xray-acme
        rm -f /etc/nginx/sites-enabled/default
        nginx -t >/dev/null 2>&1 || die "HTTP-конфигурация nginx для ACME невалидна."
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl restart nginx || die "Не удалось запустить nginx для ACME."
        echo "Пытаюсь получить Let's Encrypt для $MASK_DOMAIN (лог: $CERT_LOG)..."
        if certbot certonly --webroot -w "$SUBS_WEBROOT" -d "$MASK_DOMAIN" --non-interactive \
            --agree-tos --register-unsafely-without-email > "$CERT_LOG" 2>&1; then
            CERT_OK=1
        else
            CERT_OK=0
            echo "ВНИМАНИЕ: Let's Encrypt не выдан — продолжаю установку с самоподписанным сертификатом."
            echo "Причину можно посмотреть: tail -n 15 $CERT_LOG"
            tail -n 8 "$CERT_LOG" 2>/dev/null || true
        fi
    fi
    if [[ "$CERT_OK" -eq 0 || ! -f "$MASK_CERT" || ! -f "$MASK_KEY" ]]; then
        mkdir -p /etc/xray-selfsigned
        if [[ ! -s /etc/xray-selfsigned/cert.pem || ! -s /etc/xray-selfsigned/key.pem ]]; then
            openssl ecparam -genkey -name prime256v1 -out /etc/xray-selfsigned/key.pem 2>/dev/null \
                || openssl genrsa -out /etc/xray-selfsigned/key.pem 2048
            openssl req -new -x509 -days 365 -key /etc/xray-selfsigned/key.pem \
                -out /etc/xray-selfsigned/cert.pem -subj "/CN=$MASK_DOMAIN" \
                || die "Не удалось создать резервный сертификат."
            chmod 600 /etc/xray-selfsigned/key.pem
        fi
        MASK_CERT="/etc/xray-selfsigned/cert.pem"
        MASK_KEY="/etc/xray-selfsigned/key.pem"
        CERT_OK=0
        echo "Резервный сертификат: CN=$MASK_DOMAIN. Клиенты Hysteria2 получат insecure=1."
    fi
    cat > /etc/nginx/sites-available/xray-mask << NGINX_MASK_TLS_EOF
server {
    listen 127.0.0.1:$MASK_LOCAL_PORT ssl;
    server_name $MASK_DOMAIN;
    root $SUBS_WEBROOT;
    ssl_certificate $MASK_CERT;
    ssl_certificate_key $MASK_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; default_type text/plain; }
    location / { return 200 "ok\n"; }
}
NGINX_MASK_TLS_EOF
    ln -sf /etc/nginx/sites-available/xray-mask /etc/nginx/sites-enabled/xray-mask
    nginx -t >/dev/null 2>&1 || die "TLS-конфигурация nginx для маскировки невалидна."
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx 2>/dev/null || systemctl restart nginx || die "Не удалось перезагрузить nginx."
    REALITY_TARGET="127.0.0.1:$MASK_LOCAL_PORT"
else
    REALITY_TARGET="$MASK_DOMAIN:443"
    CERT_OK=0
    echo "ВНИМАНИЕ: режим external показывает сертификат стороннего домена и может быть заблокирован хостингом."
fi
MASK_PATH="/$(openssl rand -hex 12)"

# ── 2. BBR ────────────────────────────────────────────────────────────────────
bbr=$(sysctl -a 2>/dev/null | grep -E '^net\.ipv4\.tcp_congestion_control')
if [ "$bbr" = "net.ipv4.tcp_congestion_control = bbr" ]; then
    echo "bbr уже включен"
else
    grep -q '^net.core.default_qdisc=fq' /etc/sysctl.conf 2>/dev/null || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    echo "bbr включен"
fi

# ── 3. Установка ядра Xray ──────────────────────────────────────────────────
bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version "$XRAY_VERSION" || die "Не удалось установить Xray-core $XRAY_VERSION"
command -v xray >/dev/null 2>&1 || die "xray не найден после установки"

mkdir -p /usr/local/etc/xray
[ -f "$KEYS" ] && rm -f "$KEYS"
{
    printf 'shortsid: %s\n' "$(openssl rand -hex 8)"
    printf 'uuid: %s\n' "$(xray uuid)"
    xray x25519
} > "$KEYS" || die "Не удалось сгенерировать ключи"

uuid=$(awk -F': ' '/^uuid/ {print $2}' "$KEYS" | head -n1)
privatkey=$(awk -F': ' '/^PrivateKey/ {print $2}' "$KEYS" | head -n1)
publickey=$(awk -F': ' '/^Password/ {print $2}' "$KEYS" | head -n1)
[[ -z "$publickey" ]] && publickey=$(awk -F': ' '/^PublicKey/ {print $2}' "$KEYS" | head -n1)
shortsid=$(awk -F': ' '/^shortsid/ {print $2}' "$KEYS" | head -n1)
[[ -n "$uuid" && -n "$privatkey" && -n "$publickey" && -n "$shortsid" ]] || die "Не удалось сгенерировать ключи"
chmod 600 "$KEYS"
SHORT_ID_2=$(openssl rand -hex 8)
SHORT_ID_3=$(openssl rand -hex 8)
HY2_OBFS_PASSWORD=$(openssl rand -hex 16)

cat > "$SETTINGS" << SETTINGS_EOF
tcp_port: $TCP_PORT
xhttp_port: $XHTTP_PORT
hy2_port: $HY2_PORT
subs_port: $SUBS_PORT
fp: $DEFAULT_FP
mask_domain: $MASK_DOMAIN
mask_mode: $MASK_MODE
mask_local_port: $MASK_LOCAL_PORT
mask_path: $MASK_PATH
hy2_obfs: $HY2_OBFS
hy2_obfs_password: $HY2_OBFS_PASSWORD
hy2_insecure: 0
cert_ok: $CERT_OK
xray_version: $XRAY_VERSION
hy2_version: $HY2_VERSION
SETTINGS_EOF
chmod 600 "$SETTINGS"

# ── 3.5 Hysteria2 (QUIC) ─────────────────────────────────────────────────────
# Xray-core Hysteria2 не поддерживает, поэтому ставим официальный бинарник
# apernet/hysteria отдельным сервисом. Авторизация userpass: имя = email клиента,
# пароль = его UUID — генерируются/отзываются вместе с VLESS-пользователями.
hy2_arch=$(uname -m)
case "$hy2_arch" in
    x86_64)  hy2_arch="amd64" ;;
    aarch64) hy2_arch="arm64" ;;
    armv7l)  hy2_arch="arm"   ;;
    *) die "Неподдерживаемая архитектура для Hysteria2: $(uname -m)." ;;
esac
hy2_base="https://github.com/apernet/hysteria/releases/download/${HY2_VERSION}"
hy2_hash_file=$(mktemp)
curl -4 -fsSL -o /usr/local/bin/hysteria "${hy2_base}/hysteria-linux-${hy2_arch}" \
    || die "Не удалось скачать Hysteria2 ${HY2_VERSION} (hysteria-linux-${hy2_arch})."
curl -4 -fsSL -o "$hy2_hash_file" "${hy2_base}/hashes.txt" \
    || die "Не удалось скачать hashes.txt для Hysteria2 ${HY2_VERSION}."
hy2_expected=$(awk -v n="hysteria-linux-${hy2_arch}" '$2 ~ ("/" n "$") || $2 == n {print $1; exit}' "$hy2_hash_file")
hy2_actual=$(sha256sum /usr/local/bin/hysteria | awk '{print $1}')
[[ -n "$hy2_expected" && "$hy2_expected" == "$hy2_actual" ]] \
    || die "Контрольная сумма Hysteria2 не совпала (expected=$hy2_expected actual=$hy2_actual) — установка прервана."
echo "Hysteria2 ${HY2_VERSION}: SHA256 совпадает."
rm -f "$hy2_hash_file"
chmod 755 /usr/local/bin/hysteria
/usr/local/bin/hysteria version >/dev/null 2>&1 || die "Скачанный бинарник Hysteria2 не запускается."

mkdir -p /etc/hysteria
if [[ "$CERT_OK" -eq 1 && -f "$MASK_CERT" && -f "$MASK_KEY" ]]; then
    cp "$MASK_CERT" /etc/hysteria/cert.pem
    cp "$MASK_KEY" /etc/hysteria/key.pem
    echo "Hysteria2 использует сертификат Let's Encrypt домена $MASK_DOMAIN (insecure=1 не нужен)."
else
    if [[ ! -s /etc/xray-selfsigned/cert.pem || ! -s /etc/xray-selfsigned/key.pem ]]; then
        mkdir -p /etc/xray-selfsigned
        openssl ecparam -genkey -name prime256v1 -out /etc/xray-selfsigned/key.pem 2>/dev/null \
            || openssl genrsa -out /etc/xray-selfsigned/key.pem 2048
        openssl req -new -x509 -days 365 -key /etc/xray-selfsigned/key.pem \
            -out /etc/xray-selfsigned/cert.pem -subj "/CN=$MASK_DOMAIN" \
            || die "Не удалось создать сертификат для Hysteria2."
    fi
    cp /etc/xray-selfsigned/cert.pem /etc/hysteria/cert.pem
    cp /etc/xray-selfsigned/key.pem /etc/hysteria/key.pem
    sed -i "s/^hy2_insecure: .*/hy2_insecure: 1/" "$SETTINGS"
    echo "Hysteria2 использует временный самоподписанный сертификат (insecure=1)."
fi
chmod 600 /etc/hysteria/key.pem /etc/hysteria/cert.pem

cat > /etc/systemd/system/hysteria-server.service << HY2UNIT_EOF
[Unit]
Description=Hysteria2 Server (QUIC)
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
WorkingDirectory=/etc/hysteria
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
HY2UNIT_EOF

echo "Hysteria2 успешно установлен: /usr/local/bin/hysteria (порт $HY2_PORT)"

# ── 4. config.json: два inbound-соединения ──────────────────────────────────
cat << CONFIGEOF > "$CONFIG"
{
    "log": {
        "loglevel": "warning"
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "domain": ["geosite:category-ads-all"],
                "outboundTag": "block"
            }
        ]
    },
    "inbounds": [
        {
            "tag": "vless-tcp",
            "listen": "0.0.0.0",
            "port": $TCP_PORT,
            "protocol": "vless",
            "settings": {
                "clients": [
                    { "email": "main", "id": "$uuid", "flow": "xtls-rprx-vision" }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "target": "$REALITY_TARGET",
                    "xver": 0,
                    "serverNames": ["$MASK_DOMAIN"],
                    "privateKey": "$privatkey",
                    "minClientVer": "",
                    "maxClientVer": "",
                    "maxTimeDiff": 0,
                    "shortIds": ["$shortsid", "$SHORT_ID_2", "$SHORT_ID_3"]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        },
        {
            "tag": "vless-xhttp",
            "listen": "0.0.0.0",
            "port": $XHTTP_PORT,
            "protocol": "vless",
            "settings": {
                "clients": [
                    { "email": "main", "id": "$uuid", "flow": "" }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": { "path": "$MASK_PATH", "host": "$MASK_DOMAIN", "mode": "auto" },
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "target": "$REALITY_TARGET",
                    "serverNames": ["$MASK_DOMAIN"],
                    "privateKey": "$privatkey",
                    "minClientVer": "",
                    "maxClientVer": "",
                    "maxTimeDiff": 0,
                    "shortIds": ["$shortsid", "$SHORT_ID_2", "$SHORT_ID_3"]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
            }
        }
    ],
    "outbounds": [
        { "protocol": "freedom", "tag": "direct" },
        { "protocol": "blackhole", "tag": "block" }
    ],
    "policy": {
        "levels": {
            "0": { "handshake": 3, "connIdle": 180 }
        }
    }
}
CONFIGEOF

jq empty "$CONFIG" 2>/dev/null || die "Сгенерированный config.json некорректен (проверьте jq/переменные)"
if command -v xray >/dev/null 2>&1; then
    xray run -test -config "$CONFIG" >/tmp/xray-initial-test.$$.log 2>&1 || {
        cat /tmp/xray-initial-test.$$.log >&2
        rm -f /tmp/xray-initial-test.$$.log
        die "Начальная конфигурация Xray не прошла встроенную проверку."
    }
    rm -f /tmp/xray-initial-test.$$.log
fi

echo "Конфигурация Xray создана и проверена: $CONFIG"

# ── 5. Общая библиотека функций /usr/local/etc/xray/lib.sh ─────────────────
cat << 'LIB_EOF' > "$LIB"
#!/bin/bash
# Общая библиотека для команд управления Xray. Подключается через `source`.

CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"
SETTINGS="/usr/local/etc/xray/.settings"
SERVER_ADDRESS_FILE="/usr/local/etc/xray/server-address"

die() {
    echo "Ошибка: $1" >&2
    exit 1
}

check_deps() {
    for bin in jq xray qrencode curl ip awk; do
        command -v "$bin" >/dev/null 2>&1 || die "Не найдена утилита '$bin'."
    done
    [[ -f "$CONFIG" ]] || die "Конфигурационный файл $CONFIG не найден."
    [[ -f "$KEYS" ]] || die "Файл ключей $KEYS не найден."
}

load_keys() {
    MAIN_UUID=$(awk -F': ' '/^uuid/ {print $2}' "$KEYS" | head -n1)
    PRIVATE_KEY=$(awk -F': ' '/^PrivateKey/ {print $2}' "$KEYS" | head -n1)
    PUBLIC_KEY=$(awk -F': ' '/^Password/ {print $2}' "$KEYS" | head -n1)
    if [[ -z "$PUBLIC_KEY" ]]; then
        PUBLIC_KEY=$(awk -F': ' '/^PublicKey/ {print $2}' "$KEYS" | head -n1)
    fi
    SHORT_ID=$(awk -F': ' '/^shortsid/ {print $2}' "$KEYS" | head -n1)
    [[ -n "$MAIN_UUID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && -n "$SHORT_ID" ]] || die "Не удалось прочитать все ключи из $KEYS"
}

load_settings() {
    TCP_PORT=$(awk -F': ' '/^tcp_port/ {print $2}' "$SETTINGS")
    XHTTP_PORT=$(awk -F': ' '/^xhttp_port/ {print $2}' "$SETTINGS")
    FP=$(awk -F': ' '/^fp/ {print $2}' "$SETTINGS")
    [[ -z "$FP" ]] && FP="chrome"
    HY2_PORT=$(awk -F': ' '/^hy2_port/ {print $2}' "$SETTINGS")
    [[ "$HY2_PORT" =~ ^[0-9]+$ ]] || HY2_PORT=443
    SUBS_PORT=$(awk -F': ' '/^subs_port/ {print $2}' "$SETTINGS")
    [[ "$SUBS_PORT" =~ ^[0-9]+$ ]] || SUBS_PORT=9443
    MASK_DOMAIN=$(awk -F': ' '/^mask_domain/ {print $2}' "$SETTINGS")
    MASK_PATH=$(awk -F': ' '/^mask_path/ {print $2}' "$SETTINGS")
    HY2_OBFS=$(awk -F': ' '/^hy2_obfs/ {print $2}' "$SETTINGS")
    HY2_OBFS_PASSWORD=$(awk -F': ' '/^hy2_obfs_password/ {print $2}' "$SETTINGS")
    HY2_INSECURE=$(awk -F': ' '/^hy2_insecure/ {print $2}' "$SETTINGS")
}

get_ip() {
    local ip=""
    if [[ -f /usr/local/etc/xray/server-address ]]; then
        ip=$(head -n1 /usr/local/etc/xray/server-address | tr -d '\r')
    fi
    if [[ -z "$ip" ]]; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    fi
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    [[ -n "$ip" ]] || die "Не задан адрес сервера. Укажите его в /usr/local/etc/xray/server-address."
    echo "$ip"
}

validate_link_material() {
    local ip="$1" sni="$2" pbk="$3" sid="$4"
    [[ -n "$ip" && "$ip" != "YOUR_SERVER_IP" ]] || die "Некорректный адрес сервера: '$ip'"
    [[ -n "$sni" ]] || die "Пустой SNI в конфигурации."
    [[ -n "$pbk" ]] || die "Пустой public key (pbk). Проверьте /usr/local/etc/xray/.keys."
    [[ "$sid" =~ ^[0-9a-fA-F]{0,16}$ && $(( ${#sid} % 2 )) -eq 0 ]] || die "Некорректный shortId: '$sid'"
}

validate_xray_config() {
    command -v xray >/dev/null 2>&1 || die "xray не найден."
    xray run -test -config "$CONFIG" >/tmp/xray-config-test.$$.log 2>&1 || {
        cat /tmp/xray-config-test.$$.log >&2
        rm -f /tmp/xray-config-test.$$.log
        die "Проверка конфигурации Xray не пройдена."
    }
    rm -f /tmp/xray-config-test.$$.log
}

restart_xray() {
    # config.json пересоздаётся через `mv tmp $CONFIG`, а mktemp создаёт tmp-файл
    # с правами 600 — после mv служба (запущенная не от root) не сможет его прочитать.
    # Поэтому права фиксируем перед каждым перезапуском.
    if [[ -f "$CONFIG" ]]; then
        if id xray >/dev/null 2>&1; then
            chown root:xray "$CONFIG" 2>/dev/null || true
            chmod 640 "$CONFIG" || echo "Внимание: не удалось установить права 640 на $CONFIG"
        else
            chmod 600 "$CONFIG" || echo "Внимание: не удалось установить права 600 на $CONFIG"
        fi
    fi

    validate_xray_config
    systemctl daemon-reload
    systemctl restart xray || die "Не удалось перезапустить службу xray"

    # Даём службе немного времени вместо разового sleep + однократной проверки,
    # чтобы не выдавать ложное предупреждение при чуть более медленном старте.
    local tries=0
    while (( tries < 10 )); do
        systemctl is-active --quiet xray && break
        sleep 0.3
        ((tries++))
    done

    if systemctl is-active --quiet xray; then
        echo "Служба xray перезапущена"
    else
        echo "Внимание: служба xray не активна (код: $(systemctl show -p ExecMainStatus --value xray 2>/dev/null))."
        echo "Последние строки журнала:"
        journalctl -u xray -n 15 --no-pager 2>/dev/null
    fi
}

# $1 = uuid  $2 = email   -> заполняет TCP_LINK, XHTTP_LINK и HY2_LINK
gen_links() {
    local uuid="$1" email="$2"
    load_keys
    load_settings
    local ip; ip=$(get_ip)
    local sni_tcp sni_xhttp mask_path xhttp_host
    sni_tcp=$(jq -r '.inbounds[] | select(.streamSettings.network=="tcp") | .streamSettings.realitySettings.serverNames[0]' "$CONFIG")
    sni_xhttp=$(jq -r '.inbounds[] | select(.streamSettings.network=="xhttp") | .streamSettings.realitySettings.serverNames[0]' "$CONFIG")
    mask_path="${MASK_PATH:-/}"
    xhttp_host="${MASK_DOMAIN:-$sni_tcp}"
    validate_link_material "$ip" "$sni_tcp" "$PUBLIC_KEY" "$SHORT_ID"
    validate_link_material "$ip" "$sni_xhttp" "$PUBLIC_KEY" "$SHORT_ID"
    [[ -n "$uuid" && "$uuid" != "null" ]] || die "Для клиента '$email' не найден UUID."

    local frag; frag=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$email")
    local sni_tcp_enc sni_xhttp_enc mask_path_enc xhttp_host_enc
    sni_tcp_enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$sni_tcp")
    sni_xhttp_enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$sni_xhttp")
    mask_path_enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$mask_path")
    xhttp_host_enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$xhttp_host")

    TCP_LINK="vless://${uuid}@${ip}:${TCP_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni_tcp_enc}&fp=${FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F&type=tcp#${frag}-tcp"
    XHTTP_LINK="vless://${uuid}@${ip}:${XHTTP_PORT}?encryption=none&security=reality&sni=${sni_xhttp_enc}&fp=${FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F&type=xhttp&path=${mask_path_enc}&host=${xhttp_host_enc}&mode=auto#${frag}-xhttp"
    # userpass-авторизация Hysteria2: в URI это username:password (имя:UUID клиента).
    local hy2_query="sni=${sni_tcp_enc}"
    if [[ "${HY2_OBFS:-no}" == "yes" && -n "${HY2_OBFS_PASSWORD:-}" ]]; then
        local obfs_enc
        obfs_enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$HY2_OBFS_PASSWORD")
        hy2_query+="&obfs=salamander&obfs-password=${obfs_enc}"
    fi
    if [[ "${HY2_INSECURE:-0}" == "1" ]]; then
        hy2_query+="&insecure=1"
    fi
    HY2_LINK="hysteria2://${frag}:${uuid}@${ip}:${HY2_PORT}/?${hy2_query}#${frag}-hy2"
}

print_links() {
    local email="$1"
    local is_hy2
    is_hy2=$(command -v hysteria >/dev/null 2>&1 && echo yes || echo no)
    echo ""
    echo "== $email : TCP =="
    echo "$TCP_LINK"
    echo "$TCP_LINK" | qrencode -t ansiutf8
    echo ""
    echo "== $email : XHTTP =="
    echo "$XHTTP_LINK"
    echo "$XHTTP_LINK" | qrencode -t ansiutf8
    if [[ "$is_hy2" == "yes" ]]; then
        echo ""
        echo "== $email : Hysteria2 (UDP) =="
        echo "$HY2_LINK"
        echo "$HY2_LINK" | qrencode -t ansiutf8
    fi
}

# Определяет outboundTag, который следует считать "туннелем" для нетранзитного
# (не-RU) трафика: если настроен каскад (setcascade), используем его тег,
# иначе трафик и так выходит с этого сервера напрямую (freedom).
# Результат кладёт в глобальную переменную TUNNEL_TAG.
resolve_tunnel_tag() {
    if jq -e '.outbounds[]? | select(.tag == "cascade")' "$CONFIG" >/dev/null 2>&1; then
        TUNNEL_TAG="cascade"
    else
        TUNNEL_TAG="direct"
    fi
}
LIB_EOF
chmod +x "$LIB"
echo "Библиотека создана: $LIB"

# ── 6. Команды управления в /usr/local/bin/ ─────────────────────────────────

cat << 'USERLIST_EOF' > /usr/local/bin/userlist
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps
mapfile -t emails < <(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG")
if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Список клиентов пуст"
    exit 0
fi
echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
USERLIST_EOF
chmod +x /usr/local/bin/userlist

cat << 'MAINUSER_EOF' > /usr/local/bin/mainuser
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps
load_keys
main_email=$(jq -r --arg id "$MAIN_UUID" '.inbounds[0].settings.clients[] | select(.id==$id) | .email' "$CONFIG")
[[ -z "$main_email" ]] && main_email="main"
gen_links "$MAIN_UUID" "$main_email"
print_links "$main_email"
MAINUSER_EOF
chmod +x /usr/local/bin/mainuser

cat << 'NEWUSER_EOF' > /usr/local/bin/newuser
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps
read -rp "Введите имя пользователя (email): " email
if [[ -z "$email" || "$email" == *" "* ]]; then
    die "Имя пользователя не может быть пустым или содержать пробелы."
fi

exists=$(jq --arg email "$email" '.inbounds[0].settings.clients[] | select(.email==$email)' "$CONFIG")
if [[ -n "$exists" ]]; then
    die "Пользователь с таким именем уже существует."
fi

new_uuid=$(xray uuid)
tmp=$(mktemp)
jq --arg email "$email" --arg uuid "$new_uuid" '
  (.inbounds[] | select(.streamSettings.network=="tcp")   | .settings.clients) += [{"email":$email,"id":$uuid,"flow":"xtls-rprx-vision"}] |
  (.inbounds[] | select(.streamSettings.network=="xhttp") | .settings.clients) += [{"email":$email,"id":$uuid,"flow":""}]
' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG" || die "Не удалось обновить конфигурацию"

restart_xray
[[ -x /usr/local/bin/hysteria ]] && hy2sync
gen_links "$new_uuid" "$email"
print_links "$email"
if [[ -n "$(cat /usr/local/etc/xray/subscription-domain 2>/dev/null)" ]]; then
    /usr/local/bin/subscription create "$new_uuid" "$email"
fi
NEWUSER_EOF
chmod +x /usr/local/bin/newuser

cat << 'RMUSER_EOF' > /usr/local/bin/rmuser
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps
mapfile -t emails < <(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG")
if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Нет клиентов для удаления."
    exit 0
fi
echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
read -rp "Введите номер клиента для удаления: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
    die "Номер должен быть от 1 до ${#emails[@]}"
fi
selected="${emails[$((choice-1))]}"
selected_uuid=$(jq -r --arg email "$selected" ".inbounds[0].settings.clients[] | select(.email==\$email) | .id" "$CONFIG")
if [[ "$selected" == "main" ]]; then
    die "Нельзя удалить основного пользователя main."
fi
tmp=$(mktemp)
jq --arg email "$selected" '(.inbounds[].settings.clients) |= map(select(.email != $email))' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG" || die "Не удалось обновить конфигурацию"
restart_xray
if [[ -x /usr/local/bin/hysteria ]]; then
    hy2sync
    echo "Пользователь удалён и из Hysteria2."
fi
if command -v subscription >/dev/null 2>&1 && [[ -n "${selected_uuid:-}" ]]; then
    /usr/local/bin/subscription remove-uuid "$selected_uuid" 2>/dev/null || true
fi
echo "Клиент $selected удалён."
RMUSER_EOF
chmod +x /usr/local/bin/rmuser

cat << 'SHARELINK_EOF' > /usr/local/bin/sharelink
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps
mapfile -t emails < <(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG")
if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Список клиентов пуст"
    exit 0
fi
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
read -rp "Выберите клиента: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
    die "Номер должен быть от 1 до ${#emails[@]}"
fi
selected="${emails[$((choice-1))]}"
uid=$(jq -r --arg email "$selected" '.inbounds[0].settings.clients[] | select(.email==$email) | .id' "$CONFIG")
gen_links "$uid" "$selected"
print_links "$selected"
SHARELINK_EOF
chmod +x /usr/local/bin/sharelink

cat << 'HY2SYNC_EOF' > /usr/local/bin/hy2sync
#!/bin/bash
# Пересобирает /etc/hysteria/config.yaml из текущего списка клиентов config.json:
# auth userpass, имя = email, пароль = UUID. Возвращает 0, если Hysteria2 не установлен.
source /usr/local/etc/xray/lib.sh
if [[ ! -x /usr/local/bin/hysteria ]]; then
    exit 0
fi
HY2_PORT=$(awk -F': ' '/^hy2_port/ {print $2}' "$SETTINGS")
[[ "$HY2_PORT" =~ ^[0-9]+$ ]] || HY2_PORT=443
tmp=$(mktemp)
{
    if [[ "${HY2_OBFS:-no}" == "yes" && -n "${HY2_OBFS_PASSWORD:-}" ]]; then
        cat << HY2CONF_HEAD
listen: :$HY2_PORT

tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem

obfs:
  type: salamander
  salamander:
    password: $HY2_OBFS_PASSWORD

auth:
  type: userpass
  userpass:
HY2CONF_HEAD
    else
        cat << HY2CONF_HEAD
listen: :$HY2_PORT

tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem

auth:
  type: userpass
  userpass:
HY2CONF_HEAD
    fi
    jq -r '.inbounds[0].settings.clients[] | "    \(.email): \(.id)"' /usr/local/etc/xray/config.json
    cat << 'HY2CONF_TAIL'

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
HY2CONF_TAIL
} > "$tmp" || { rm -f "$tmp"; die "Не удалось сгенерировать конфиг Hysteria2"; }
chmod 600 "$tmp"
mv "$tmp" /etc/hysteria/config.yaml || { rm -f "$tmp"; die "Не удалось сохранить /etc/hysteria/config.yaml"; }
systemctl restart hysteria-server 2>/dev/null || {
    systemctl daemon-reload
    systemctl restart hysteria-server || die "Не удалось перезапустить hysteria-server"
}
HY2SYNC_EOF
chmod +x /usr/local/bin/hy2sync

cat << 'HY2RESTART_EOF' > /usr/local/bin/hy2restart
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps
[[ -x /usr/local/bin/hysteria ]] || die "Hysteria2 не установлен (/usr/local/bin/hysteria не найден)."
load_settings
load_keys
hy2sync
sleep 1
if systemctl is-active --quiet hysteria-server; then
    echo "Служба hysteria-server перезапущена и активна. Порт (UDP): $HY2_PORT"
else
    echo "Внимание: служба hysteria-server не активна. Последние строки журнала:"
    journalctl -u hysteria-server -n 20 --no-pager 2>/dev/null
    exit 1
fi
main_email=$(jq -r --arg id "$MAIN_UUID" '.inbounds[0].settings.clients[] | select(.id==$id) | .email' "$CONFIG")
[[ -z "$main_email" ]] && main_email="main"
gen_links "$MAIN_UUID" "$main_email"
printf 'Ссылка main в Hysteria2:\n%s\n' "$HY2_LINK"
HY2RESTART_EOF
chmod +x /usr/local/bin/hy2restart

echo "Команды newuser/rmuser/userlist/sharelink/mainuser/hy2sync/hy2restart созданы"

cat << 'SETMASK_EOF' > /usr/local/bin/setmask
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps

# Считаем текущих клиентов ДО любых изменений, чтобы гарантированно вернуть
# их обратно, даже если сам фильтр маскировки их не трогает — это защита
# от регрессий, а не признание того, что нынешний фильтр их стирает.
tcp_clients=$(jq -c '.inbounds[] | select(.streamSettings.network=="tcp")   | .settings.clients' "$CONFIG")
xhttp_clients=$(jq -c '.inbounds[] | select(.streamSettings.network=="xhttp") | .settings.clients' "$CONFIG")
[[ -z "$tcp_clients" || "$tcp_clients" == "null" ]] && tcp_clients='[]'
[[ -z "$xhttp_clients" || "$xhttp_clients" == "null" ]] && xhttp_clients='[]'
before_count=$(jq -r '.inbounds[0].settings.clients | length' "$CONFIG")

# Применяет jq-фильтр $1 к $CONFIG через безопасную запись во временный файл:
# 1) проверяет, что результат — валидный JSON и не пустой;
# 2) проверяет, что число клиентов не уменьшилось;
# 3) только после этого делает mv поверх боевого конфига.
apply_config_change() {
    local filter="$1"; shift
    local tmp; tmp=$(mktemp)

    if ! jq --arg tcp_clients_raw "$tcp_clients" --arg xhttp_clients_raw "$xhttp_clients" \
            --argjson tcp_clients "$tcp_clients" --argjson xhttp_clients "$xhttp_clients" \
            "$filter" "$@" "$CONFIG" > "$tmp"; then
        rm -f "$tmp"
        die "jq не смог применить изменения (конфигурация не тронута)"
    fi

    if ! jq empty "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        die "Результат обновления — невалидный JSON, отменено (конфигурация не тронута)"
    fi

    local after_count
    after_count=$(jq -r '.inbounds[0].settings.clients | length' "$tmp")
    if [[ -z "$after_count" || "$after_count" -lt "$before_count" ]]; then
        rm -f "$tmp"
        die "Проверка не пройдена: было $before_count клиентов, стало ${after_count:-0}. Конфигурация не изменена."
    fi

    mv "$tmp" "$CONFIG" || die "Не удалось сохранить конфигурацию"
}

echo "Настройка маскировки Reality"
echo "1) Изменить SNI (свой домен, сертификат будет перевыпущен)"
echo "2) Добавить новый shortId (старые остаются действительными)"
echo "3) Изменить fingerprint (fp) по умолчанию для новых ссылок"
read -rp "Выберите пункт: " opt
case "$opt" in
  1)
    read -rp "Новый домен маскировки (свой домен с A-записью на сервер): " domain
    [[ -z "$domain" ]] && die "Домен не может быть пустым"
    for banned in github.com www.github.com google.com www.google.com cloudflare.com microsoft.com apple.com amazon.com; do
        [[ "${domain,,}" == "$banned" ]] && die "Домен $banned запрещён как SNI хостингом."
    done
    local_mode=$(awk -F': ' '/^mask_mode/ {print $2}' "$SETTINGS")
    local_target="$domain:443"
    if [[ "$local_mode" != "external" ]]; then
        certbot certonly --webroot -w /var/www/xray-subscriptions -d "$domain" --non-interactive \
            --agree-tos --register-unsafely-without-email >/dev/null 2>&1 || die "Не удалось выпустить сертификат для $domain"
        local_port=$(awk -F': ' '/^mask_local_port/ {print $2}' "$SETTINGS")
        [[ "$local_port" =~ ^[0-9]+$ ]] || local_port=8444
        mask_cert="/etc/letsencrypt/live/$domain/fullchain.pem"
        mask_key="/etc/letsencrypt/live/$domain/privkey.pem"
        cat > /etc/nginx/sites-available/xray-mask << NGINX_MASK_UPDATE_EOF
server {
    listen 127.0.0.1:$local_port ssl;
    server_name $domain;
    ssl_certificate $mask_cert;
    ssl_certificate_key $mask_key;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / { return 200 "ok\n"; }
}
NGINX_MASK_UPDATE_EOF
        nginx -t >/dev/null 2>&1 || die "Новая TLS-конфигурация nginx невалидна."
        systemctl reload nginx 2>/dev/null || systemctl restart nginx || die "Не удалось перезагрузить nginx."
        cp "$mask_cert" /etc/hysteria/cert.pem 2>/dev/null || true
        cp "$mask_key" /etc/hysteria/key.pem 2>/dev/null || true
        chmod 600 /etc/hysteria/key.pem /etc/hysteria/cert.pem 2>/dev/null || true
        local_target="127.0.0.1:$local_port"
        sed -i "s/^mask_domain: .*/mask_domain: $domain/" "$SETTINGS"
    fi
    apply_config_change '
      (.inbounds[].streamSettings.realitySettings.target) = $t |
      del(.inbounds[].streamSettings.realitySettings.dest) |
      (.inbounds[].streamSettings.realitySettings.serverNames) = [$d] |
      (.inbounds[] | select(.streamSettings.network=="xhttp") | .streamSettings.xhttpSettings.host) = $d |
      (.inbounds[] | select(.streamSettings.network=="tcp")   | .settings.clients) = $tcp_clients |
      (.inbounds[] | select(.streamSettings.network=="xhttp") | .settings.clients) = $xhttp_clients
    ' --arg d "$domain" --arg t "$local_target"
    restart_xray
    command -v subscription >/dev/null 2>&1 && subscription refresh-all
    echo "SNI обновлён на $domain (пользователи сохранены)"
    ;;
  2)
    new_sid=$(openssl rand -hex 8)
    apply_config_change '
      (.inbounds[].streamSettings.realitySettings.shortIds) += [$sid] |
      (.inbounds[] | select(.streamSettings.network=="tcp")   | .settings.clients) = $tcp_clients |
      (.inbounds[] | select(.streamSettings.network=="xhttp") | .settings.clients) = $xhttp_clients
    ' --arg sid "$new_sid"
    sed -i "s/^shortsid: .*/shortsid: $new_sid/" "$KEYS"
    restart_xray
    command -v subscription >/dev/null 2>&1 && subscription refresh-all
    echo "Новый shortId добавлен и установлен основным для генерации ссылок: $new_sid (пользователи сохранены)"
    ;;
  3)
    read -rp "Новый fingerprint (chrome/firefox/safari/ios/android/edge/random): " fp
    [[ -z "$fp" ]] && die "Значение не может быть пустым"
    if grep -q '^fp:' "$SETTINGS" 2>/dev/null; then
      sed -i "s/^fp: .*/fp: $fp/" "$SETTINGS"
    else
      echo "fp: $fp" >> "$SETTINGS"
    fi
    echo "Fingerprint по умолчанию обновлён на $fp (применится к новым ссылкам)"
    command -v subscription >/dev/null 2>&1 && subscription refresh-all
    ;;
  *) die "Неизвестный пункт меню" ;;
esac
SETMASK_EOF
chmod +x /usr/local/bin/setmask


cat << 'SETCASCADE_EOF' > /usr/local/bin/setcascade
#!/bin/bash
# Настройка каскада (proxy chaining): весь исходящий трафик (кроме рекламы/CN)
# уходит через внешний vless-сервер, ссылка на который парсится автоматически.
source /usr/local/etc/xray/lib.sh
check_deps
command -v python3 >/dev/null 2>&1 || die "Требуется python3 для разбора vless-ссылки"

CASCADE_TAG="cascade"

url_decode() {
    python3 -c "import urllib.parse,sys;print(urllib.parse.unquote(sys.argv[1]))" "$1"
}

parse_vless() {
    local url="$1" rest frag hostport query pair k v
    [[ "$url" == vless://* ]] || die "Это не vless:// ссылка"
    rest="${url#vless://}"
    frag=""
    if [[ "$rest" == *"#"* ]]; then
        frag="${rest##*#}"
        frag=$(url_decode "$frag")
        rest="${rest%%#*}"
    fi
    v_id="${rest%%@*}"
    rest="${rest#*@}"
    hostport="${rest%%\?*}"
    query=""
    [[ "$rest" == *"?"* ]] && query="${rest#*\?}"
    if [[ "$hostport" == \[* ]]; then
        v_address="${hostport%%]*}"; v_address="${v_address#[}"
        v_port="${hostport##*]:}"
    else
        v_address="${hostport%%:*}"; v_port="${hostport##*:}"
    fi
    [[ "$v_port" =~ ^[0-9]+$ ]] || die "Не удалось определить порт в ссылке"

    declare -gA vp=()
    local IFS='&'
    for pair in $query; do
        k="${pair%%=*}"; v="${pair#*=}"
        v=$(url_decode "$v")
        vp["$k"]="$v"
    done
    v_pbk="${vp[pbk]:-}"
    v_fp="${vp[fp]:-firefox}"
    v_sni="${vp[sni]:-}"
    v_sid="${vp[sid]:-}"
    v_type="${vp[type]:-tcp}"
    v_name="${frag:-cascade}"
    [[ -n "$v_pbk" && -n "$v_sni" ]] || die "В ссылке отсутствуют обязательные параметры pbk/sni"
}

echo "Настройка каскада (proxy chaining)"
read -rp "Вставьте vless-ссылку внешнего сервера: " vless_url
parse_vless "$vless_url"

echo ""
echo "=== Параметры каскада ($v_name) ==="
echo "  адрес: $v_address:$v_port"
echo "  тип:   $v_type"
echo "  sni:   $v_sni"
echo ""

cp "$CONFIG" "${CONFIG}.backup.$(date +%s)" 2>/dev/null

tmp=$(mktemp)
case "$v_type" in
  xhttp)
    jq --arg address "$v_address" --argjson port "$v_port" --arg id "$v_id" \
       --arg tag "$CASCADE_TAG" --arg pbk "$v_pbk" --arg fp "$v_fp" \
       --arg sni "$v_sni" --arg sid "$v_sid" '
      .outbounds = (.outbounds | map(select(.tag != $tag))) + [{
        "protocol":"vless",
        "tag":$tag,
        "settings":{"address":$address,"port":$port,"id":$id,"flow":"","encryption":"none"},
        "streamSettings":{
          "network":"xhttp","security":"reality",
          "realitySettings":{"publicKey":$pbk,"fingerprint":$fp,"serverName":$sni,"shortId":$sid,"spiderX":"/"},
          "xhttpSettings":{"path":"/","host":"","mode":"auto"}
        }
      }]
    ' "$CONFIG" > "$tmp"
    ;;
  tcp)
    jq --arg address "$v_address" --argjson port "$v_port" --arg id "$v_id" \
       --arg tag "$CASCADE_TAG" --arg pbk "$v_pbk" --arg fp "$v_fp" \
       --arg sni "$v_sni" --arg sid "$v_sid" '
      .outbounds = (.outbounds | map(select(.tag != $tag))) + [{
        "protocol":"vless",
        "tag":$tag,
        "settings":{"address":$address,"port":$port,"id":$id,"flow":"xtls-rprx-vision","encryption":"none"},
        "streamSettings":{
          "network":"tcp","security":"reality",
          "realitySettings":{"publicKey":$pbk,"fingerprint":$fp,"serverName":$sni,"shortId":$sid,"spiderX":"/"},
          "tcpSettings":{"header":{"type":"none"}}
        }
      }]
    ' "$CONFIG" > "$tmp"
    ;;
  *)
    rm -f "$tmp"
    die "Неподдерживаемый type='$v_type' (ожидался tcp или xhttp)"
    ;;
esac
[[ -s "$tmp" ]] && mv "$tmp" "$CONFIG" || die "Не удалось применить outbound-конфигурацию"

tmp=$(mktemp)
jq --arg tag "$CASCADE_TAG" '
  .routing.domainStrategy = "IPIfNonMatch" |
  .routing.rules = [
    {"type":"field","outboundTag":"block","domain":["geosite:category-ads-all"]},
    {"type":"field","outboundTag":$tag,"network":"tcp,udp"}
  ]
' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG" || die "Не удалось обновить routing"

restart_xray
echo "Каскад через $v_address:$v_port настроен (тег outbound: $CASCADE_TAG)."
echo "Резервная копия предыдущего config.json сохранена рядом с ${CONFIG}."
SETCASCADE_EOF
chmod +x /usr/local/bin/setcascade

cat << 'UNSETCASCADE_EOF' > /usr/local/bin/unsetcascade
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps

CASCADE_TAG="cascade"

if ! jq -e --arg tag "$CASCADE_TAG" '.outbounds[]? | select(.tag == $tag)' "$CONFIG" >/dev/null 2>&1; then
    echo "Каскад не настроен."
    exit 0
fi

cp "$CONFIG" "${CONFIG}.backup.$(date +%s)" 2>/dev/null

tmp=$(mktemp)

jq --arg tag "$CASCADE_TAG" '
  .outbounds |= map(select(.tag != $tag)) |
  .routing.domainStrategy = "IPIfNonMatch" |
  .routing.rules = [
    {"type":"field","outboundTag":"block","domain":["geosite:category-ads-all"]}
  ]
' "$CONFIG" > "$tmp" || {
    rm -f "$tmp"
    die "Не удалось отключить каскад: ошибка jq"
}

jq empty "$tmp" 2>/dev/null || {
    rm -f "$tmp"
    die "Получился невалидный config.json, изменения отменены"
}

mv "$tmp" "$CONFIG" || die "Не удалось сохранить конфигурацию"

restart_xray
echo "Каскад отключён. Исходящий трафик снова идёт напрямую."
echo "Резервная копия предыдущего config.json сохранена рядом с ${CONFIG}."
UNSETCASCADE_EOF
chmod +x /usr/local/bin/unsetcascade

cat << 'RENEWGEO_EOF' > /usr/local/bin/renewgeo
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps
command -v wget >/dev/null 2>&1 || die "Требуется wget"
mkdir -p /usr/local/share/xray
echo "Обновление geo-файлов (runetfreedom/russia-v2ray-rules-dat)..."
wget -q -O /usr/local/share/xray/geoip.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat || die "Не удалось скачать geoip.dat"
wget -q -O /usr/local/share/xray/geosite.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat || die "Не удалось скачать geosite.dat"
restart_xray
echo "Geo-файлы обновлены в /usr/local/share/xray/."
RENEWGEO_EOF
chmod +x /usr/local/bin/renewgeo

cat << 'ROUTINGMODE_EOF' > /usr/local/bin/routingmode
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps
resolve_tunnel_tag
[[ "$TUNNEL_TAG" == "cascade" ]] || die "Каскад не настроен. Сначала выполните setcascade."
cp "$CONFIG" "${CONFIG}.backup.$(date +%s)" 2>/dev/null
tmp=$(mktemp)
jq '.routing.domainStrategy = "IPIfNonMatch" | .routing.rules = [{"type":"field","outboundTag":"direct","ip":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","169.254.0.0/16"]},{"type":"field","outboundTag":"direct","domain":["geosite:category-ru"]},{"type":"field","outboundTag":"direct","ip":["geoip:ru"]},{"type":"field","outboundTag":"cascade","network":"tcp,udp"}]' "$CONFIG" > "$tmp" || { rm -f "$tmp"; die "Не удалось включить маршрутизацию: ошибка jq"; }
jq empty "$tmp" 2>/dev/null || { rm -f "$tmp"; die "Получился невалидный config.json, изменения отменены"; }
mv "$tmp" "$CONFIG" || die "Не удалось сохранить конфигурацию"
restart_xray
echo "Маршрутизация «Умный обход РФ» ВКЛЮЧЕНА: RU -> direct, остальное -> cascade."
ROUTINGMODE_EOF
chmod +x /usr/local/bin/routingmode

cat << 'DISABLE_ROUTING_EOF' > /usr/local/bin/disable_routing
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps
cp "$CONFIG" "${CONFIG}.backup.$(date +%s)" 2>/dev/null
tmp=$(mktemp)
jq '.routing.domainStrategy = "AsIs" | .routing.rules = [{"type":"field","outboundTag":"block","domain":["geosite:category-ads-all"]}]' "$CONFIG" > "$tmp" || { rm -f "$tmp"; die "Не удалось отключить маршрутизацию: ошибка jq"; }
jq empty "$tmp" 2>/dev/null || { rm -f "$tmp"; die "Получился невалидный config.json, изменения отменены"; }
mv "$tmp" "$CONFIG" || die "Не удалось сохранить конфигурацию"
restart_xray
echo "Кастомная маршрутизация ПОЛНОСТЬЮ ОТКЛЮЧЕНА. Обычный исходящий трафик -> direct; cascade правилами routing не используется."
DISABLE_ROUTING_EOF
chmod +x /usr/local/bin/disable_routing

# ── Подписки ────────────────────────────────────────────────────────────────
mkdir -p "$SUBS_DIR" "$SUBS_WEBROOT"

# Отдельная команда, чтобы домен подписок можно было настроить/сменить и ПОСЛЕ
# установки (раньше такой возможности не было, хотя пользователю это обещалось).
cat << 'SETSUBDOMAIN_EOF' > /usr/local/bin/setsubdomain
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps

SUBS_DIR="/usr/local/etc/xray/subscriptions"
SUBS_WEBROOT="/var/www/xray-subscriptions"
SUBS_DOMAIN_FILE="/usr/local/etc/xray/subscription-domain"
SUBS_SCHEME_FILE="/usr/local/etc/xray/subscription-scheme"
load_settings   # читаем subs_port (и остальные порты) из /usr/local/etc/xray/.settings

domain="${1:-}"
if [[ -z "$domain" ]]; then
    read -rp "Домен подписок (например, sub.example.com): " domain
fi
domain="${domain#http://}"
domain="${domain#https://}"
domain="${domain%%/*}"
[[ -n "$domain" && "$domain" != *" "* && "$domain" != *"/"* ]] || die "Некорректный домен."
[[ "$SUBS_PORT" =~ ^[0-9]+$ && "$SUBS_PORT" -ge 1 && "$SUBS_PORT" -le 65535 ]] || die "Некорректный SUBS_PORT=$SUBS_PORT."
[[ "$SUBS_PORT" != "$TCP_PORT" && "$SUBS_PORT" != "$XHTTP_PORT" ]] || die "SUBS_PORT=$SUBS_PORT конфликтует с портом Xray."

if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
    echo "Устанавливаю nginx/certbot..."
    apt update && apt install -y nginx certbot || die "Не удалось установить nginx/certbot"
fi

mkdir -p "$SUBS_DIR" "$SUBS_WEBROOT"
printf '%s\n' "$domain" > "$SUBS_DOMAIN_FILE"

# nginx для подписок не занимает 443: основной TCP-Reality порт остаётся у Xray.
# HTTP :80 используется для ACME, HTTPS подписки — на отдельном порту SUBS_PORT.
cat > /etc/nginx/sites-available/xray-subscriptions << NGINX_HTTP_EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    root $SUBS_WEBROOT;

    location ^~ /.well-known/acme-challenge/ {
        try_files \$uri =404;
        default_type text/plain;
    }

    location /sub/ {
        access_log off;
        rewrite ^/sub/(.*)\$ /\$1 break;
        try_files \$uri =404;
        default_type text/plain;
        add_header Cache-Control "no-store" always;
    }

    location / {
        return 301 https://$domain:$SUBS_PORT\$request_uri;
    }
}
NGINX_HTTP_EOF

ln -sf /etc/nginx/sites-available/xray-subscriptions /etc/nginx/sites-enabled/xray-subscriptions
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || die "Конфигурация nginx не прошла проверку."
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx || die "Не удалось запустить nginx для подписок."

echo "Получаю сертификат Let's Encrypt для $domain..."
if certbot certonly --webroot -w "$SUBS_WEBROOT" -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email >/dev/null 2>&1; then
    cat > /etc/nginx/sites-available/xray-subscriptions << NGINX_HTTPS_EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    root $SUBS_WEBROOT;

    location ^~ /.well-known/acme-challenge/ {
        try_files \$uri =404;
        default_type text/plain;
    }

    location / {
        return 301 https://$domain:$SUBS_PORT\$request_uri;
    }
}

server {
    listen $SUBS_PORT ssl;
    listen [::]:$SUBS_PORT ssl;
    server_name $domain;

    root $SUBS_WEBROOT;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    location /sub/ {
        access_log off;
        rewrite ^/sub/(.*)\$ /\$1 break;
        try_files \$uri =404;
        default_type text/plain;
        add_header Cache-Control "no-store" always;
    }

    location / {
        return 404;
    }
}
NGINX_HTTPS_EOF
    nginx -t >/dev/null 2>&1 || die "HTTPS-конфигурация nginx не прошла проверку."
    systemctl reload nginx || die "Не удалось перезагрузить nginx."
    printf '%s\n' https > "$SUBS_SCHEME_FILE"
    echo "HTTPS для подписок настроен: https://$domain:$SUBS_PORT/sub/<token>"
else
    cat > /etc/nginx/sites-available/xray-subscriptions << NGINX_HTTPONLY_EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    root $SUBS_WEBROOT;

    location ^~ /.well-known/acme-challenge/ {
        try_files \$uri =404;
        default_type text/plain;
    }

    location /sub/ {
        access_log off;
        rewrite ^/sub/(.*)\$ /\$1 break;
        try_files \$uri =404;
        default_type text/plain;
        add_header Cache-Control "no-store" always;
    }

    location / { return 404; }
}
NGINX_HTTPONLY_EOF
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
    printf '%s\n' http > "$SUBS_SCHEME_FILE"
    echo "Внимание: сертификат Let's Encrypt получить не удалось."
    echo "Пока подписки доступны по HTTP: http://$domain/sub/<token>"
    echo "После настройки DNS/портов повторите: setsubdomain $domain"
fi

echo "Домен подписок сохранён: $domain"
echo "Порт HTTPS подписок: $SUBS_PORT"
echo "Если подписки уже создавались раньше — обновите их: subscription list"
SETSUBDOMAIN_EOF
chmod +x /usr/local/bin/setsubdomain

# ── Восстановление сертификата вручную и по таймеру ──────────────────────────
cat > /usr/local/bin/fixcert <<'FIXCERT_EOF'
#!/bin/bash
# Повторяет выпуск Let's Encrypt для домена маскировки и подключает сертификат
# к nginx/Hysteria2. Безопасно вызывать повторно и из таймера.
source /usr/local/etc/xray/lib.sh
check_deps
MASK_DOMAIN=$(awk -F': ' '/^mask_domain/ {print $2}' "$SETTINGS")
LOCAL_PORT=$(awk -F': ' '/^mask_local_port/ {print $2}' "$SETTINGS")
[[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || LOCAL_PORT=8444
CERT_LOG=/var/log/xray-certbot.log
cat > /etc/nginx/sites-available/xray-acme << NGINX_ACME_FIX_EOF
server {
    listen 80;
    listen [::]:80;
    server_name $MASK_DOMAIN;
    root /var/www/xray-subscriptions;
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; default_type text/plain; }
    location / { return 404; }
}
NGINX_ACME_FIX_EOF
ln -sf /etc/nginx/sites-available/xray-acme /etc/nginx/sites-enabled/xray-acme
nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
echo "Запрашиваю сертификат для $MASK_DOMAIN..."
if certbot certonly --webroot -w /var/www/xray-subscriptions -d "$MASK_DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email > "$CERT_LOG" 2>&1; then
    cat > /etc/nginx/sites-available/xray-mask << NGINX_FIXCERT_EOF
server {
    listen 127.0.0.1:$LOCAL_PORT ssl;
    server_name $MASK_DOMAIN;
    root /var/www/xray-subscriptions;
    ssl_certificate /etc/letsencrypt/live/$MASK_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$MASK_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; default_type text/plain; }
    location / { return 200 "ok\n"; }
}
NGINX_FIXCERT_EOF
    nginx -t >/dev/null 2>&1 || { echo "nginx: невалидная конфигурация" >&2; tail -n 15 "$CERT_LOG"; exit 1; }
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
    cp /etc/letsencrypt/live/$MASK_DOMAIN/fullchain.pem /etc/hysteria/cert.pem
    cp /etc/letsencrypt/live/$MASK_DOMAIN/privkey.pem /etc/hysteria/key.pem
    chmod 600 /etc/hysteria/key.pem /etc/hysteria/cert.pem
    sed -i "s/^hy2_insecure: .*/hy2_insecure: 0/" "$SETTINGS"
    sed -i "s/^cert_ok: .*/cert_ok: 1/" "$SETTINGS"
    sed -i "s/^mask_mode: .*/mask_mode: self/" "$SETTINGS"
    hy2restart >/dev/null 2>&1 || true
    subscription refresh-all >/dev/null 2>&1 || true
    echo "ГОТОВО: сертификат Let's Encrypt подключён, insecure=1 убран."
else
    echo "Сертификат снова не получен. Лог $CERT_LOG:"
    tail -n 15 "$CERT_LOG"
    exit 1
fi
FIXCERT_EOF
chmod +x /usr/local/bin/fixcert

# ── Автопродление Let's Encrypt ───────────────────────────────────────────────
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'DEPLOY_EOF'
#!/bin/sh
systemctl reload nginx >/dev/null 2>&1 || true
DEPLOY_EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
cat > /etc/systemd/system/certbot-renew.service <<'CBRENEW_UNIT_EOF'
[Unit]
Description=Renew Let's Encrypt certificates and reload nginx

[Service]
Type=oneshot
ExecStart=/bin/bash -lc "/usr/bin/certbot renew --quiet; /usr/local/bin/fixcert >/dev/null 2>&1 || true"
CBRENEW_UNIT_EOF
cat > /etc/systemd/system/certbot-renew.timer <<'CBRENEW_TIMER_EOF'
[Unit]
Description=Weekly Let's Encrypt renewal

[Timer]
OnCalendar=weekly
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
CBRENEW_TIMER_EOF
systemctl daemon-reload
systemctl enable --now certbot-renew.timer >/dev/null 2>&1 || true

if [[ -n "${SUBS_DOMAIN:-}" ]]; then
    /usr/local/bin/setsubdomain "$SUBS_DOMAIN"
fi

cat << 'SUBSCRIPTION_EOF' > /usr/local/bin/subscription
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps

SUBS_DIR="/usr/local/etc/xray/subscriptions"
SUBS_WEBROOT="/var/www/xray-subscriptions"
SUBS_DOMAIN_FILE="/usr/local/etc/xray/subscription-domain"
SUBS_SCHEME_FILE="/usr/local/etc/xray/subscription-scheme"
load_settings   # читаем subs_port (и остальные порты) из /usr/local/etc/xray/.settings

get_domain() { [[ -f "$SUBS_DOMAIN_FILE" ]] && cat "$SUBS_DOMAIN_FILE"; }
get_scheme() { [[ -f "$SUBS_SCHEME_FILE" ]] && cat "$SUBS_SCHEME_FILE" || echo https; }
sub_url() {
    local scheme domain
    scheme=$(get_scheme)
    domain=$(get_domain)
    if [[ "$scheme" == "https" ]]; then
        echo "https://${domain}:${SUBS_PORT}/sub/$1"
    else
        echo "http://${domain}/sub/$1"
    fi
}

valid_domain() { [[ -n "$1" && "$1" != *" "* && "$1" != *"/"* ]]; }

write_subscription_file() {
    local token="$1" file="$SUBS_DIR/$token" out links uuid name
    [[ -f "$file" ]] || return 1
    out=""
    while IFS=$'\t' read -r uuid name; do
        [[ -z "$uuid" ]] && continue
        gen_links "$uuid" "$name"
        out+="$TCP_LINK\n$XHTTP_LINK\n$HY2_LINK\n"
    done < <(jq -r '.clients[] | [.uuid,.name] | @tsv' "$file")
    printf '%b' "$out" | sed '/^$/d' | base64 -w0 > "$SUBS_WEBROOT/$token"
    chmod 644 "$SUBS_WEBROOT/$token"
}

new_token() { openssl rand -hex 18; }

create_sub() {
    local uuid="$1" name="$2" token file
    [[ -n "$(get_domain)" ]] || die "Сначала настройте домен подписки."
    token=$(new_token); file="$SUBS_DIR/$token"
    jq -n --arg token "$token" --arg uuid "$uuid" --arg name "$name" \
       '{token:$token,clients:[{uuid:$uuid,name:$name}]}' > "$file"
    chmod 600 "$file"
    write_subscription_file "$token"
    echo "Подписка создана: $(sub_url "$token")"
    echo "Токен: $token"
}

add_client() {
    local token="$1" uuid="$2" name="$3" file="$SUBS_DIR/$1" tmp
    [[ -f "$file" ]] || die "Подписка не найдена."
    tmp=$(mktemp)
    # Сначала убираем старую запись с тем же именем (например, "main" после
    # переустановки сервера с новым UUID), иначе в подписке копятся дубли —
    # unique_by(.uuid) их не ловит, потому что UUID у них разные.
    jq --arg uuid "$uuid" --arg name "$name" \
       '.clients |= (map(select(.name != $name)) + [{uuid:$uuid,name:$name}])' \
       "$file" > "$tmp" || { rm -f "$tmp"; die "Не удалось обновить подписку"; }
    mv "$tmp" "$file"; write_subscription_file "$token"; echo "Клиент добавлен в подписку: $(sub_url "$token")"
}

remove_client() {
    local token="$1" uuid="$2" file="$SUBS_DIR/$1" tmp
    [[ -f "$file" ]] || die "Подписка не найдена."
    tmp=$(mktemp)
    jq --arg uuid "$uuid" '.clients |= map(select(.uuid != $uuid))' "$file" > "$tmp" || { rm -f "$tmp"; die "Не удалось обновить подписку"; }
    mv "$tmp" "$file"; write_subscription_file "$token"; echo "Клиент удалён из подписки: $(sub_url "$token")"
}

remove_uuid_from_all() {
    local uuid="$1" file token tmp
    for file in "$SUBS_DIR"/*; do
        [[ -f "$file" ]] || continue
        if jq -e --arg uuid "$uuid" '.clients[]? | select(.uuid==$uuid)' "$file" >/dev/null 2>&1; then
            token=$(jq -r '.token' "$file")
            tmp=$(mktemp)
            jq --arg uuid "$uuid" '.clients |= map(select(.uuid != $uuid))' "$file" > "$tmp" && mv "$tmp" "$file"
            write_subscription_file "$token"
        fi
    done
}

refresh_all() {
    local file token
    for file in "$SUBS_DIR"/*; do
        [[ -f "$file" ]] || continue
        token=$(jq -r '.token' "$file")
        write_subscription_file "$token"
    done
}

case "${1:-menu}" in
  refresh-all)
    refresh_all
    ;;
  remove-uuid)
    [[ -n "${2:-}" ]] || exit 0
    remove_uuid_from_all "$2"
    ;;
  create)
    [[ $# -ge 3 ]] || die "Использование: subscription create UUID NAME"
    create_sub "$2" "$3" ;;
  add)
    [[ $# -ge 4 ]] || die "Использование: subscription add TOKEN UUID NAME"
    add_client "$2" "$3" "$4" ;;
  remove)
    [[ $# -ge 3 ]] || die "Использование: subscription remove TOKEN UUID"
    remove_client "$2" "$3" ;;
  list)
    for file in "$SUBS_DIR"/*; do
        [[ -f "$file" ]] || continue
        echo "$(jq -r '.token' "$file") — $(jq -r '.clients|length' "$file") клиентов — $(sub_url "$(jq -r '.token' "$file")")"
    done ;;
  show)
    [[ -f "$SUBS_DIR/$2" ]] || die "Подписка не найдена."
    jq -r '.clients[] | "\(.name) — \(.uuid)"' "$SUBS_DIR/$2" ;;
  delete)
    [[ -n "${2:-}" ]] || die "Укажите токен подписки."
    rm -f "$SUBS_DIR/$2" "$SUBS_WEBROOT/$2"
    echo "Подписка удалена." ;;
  menu)
    echo "===== Управление подписками ====="
    echo "1) Создать подписку для клиента"
    echo "2) Показать ссылку подписки"
    echo "3) Добавить клиентский ключ в подписку"
    echo "4) Удалить клиентский ключ из подписки"
    echo "5) Показать клиентов подписки"
    echo "6) Удалить подписку"
    echo "0) Назад"
    read -rp "Выберите пункт: " n

    pick_client() {
        mapfile -t emails < <(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG")
        [[ ${#emails[@]} -gt 0 ]] || die "Нет пользователей. Сначала создайте через newuser."
        for i in "${!emails[@]}"; do echo "$((i+1)). ${emails[$i]}" >&2; done
        read -rp "Выберите клиента: " c
        [[ "$c" =~ ^[0-9]+$ && "$c" -ge 1 && "$c" -le "${#emails[@]}" ]] || die "Некорректный номер"
        echo "${emails[$((c-1))]}"
    }

    pick_sub() {
        mapfile -t sub_tokens < <(ls "$SUBS_DIR" 2>/dev/null)
        [[ ${#sub_tokens[@]} -gt 0 ]] || die "Подписок пока нет. Сначала создайте через пункт 1."
        for i in "${!sub_tokens[@]}"; do
            echo "$((i+1)). ${sub_tokens[$i]} ($(jq -r '.clients|length' "$SUBS_DIR/${sub_tokens[$i]}") клиентов)" >&2
        done
        read -rp "Выберите подписку: " c
        [[ "$c" =~ ^[0-9]+$ && "$c" -ge 1 && "$c" -le "${#sub_tokens[@]}" ]] || die "Некорректный номер"
        echo "${sub_tokens[$((c-1))]}"
    }

    case "$n" in
      1)
        email=$(pick_client) || exit 1
        uuid=$(jq -r --arg e "$email" '.inbounds[0].settings.clients[] | select(.email==$e) | .id' "$CONFIG")
        create_sub "$uuid" "$email" ;;
      2)
        token=$(pick_sub) || exit 1
        echo "$(sub_url "$token")" ;;
      3)
        token=$(pick_sub) || exit 1
        email=$(pick_client) || exit 1
        uuid=$(jq -r --arg e "$email" '.inbounds[0].settings.clients[] | select(.email==$e) | .id' "$CONFIG")
        add_client "$token" "$uuid" "$email" ;;
      4)
        token=$(pick_sub) || exit 1
        jq -r '.clients[] | "\(.name) — \(.uuid)"' "$SUBS_DIR/$token"
        read -rp "Имя клиента для удаления из подписки: " name
        uuid=$(jq -r --arg n "$name" '.clients[] | select(.name==$n) | .uuid' "$SUBS_DIR/$token")
        [[ -n "$uuid" ]] || die "Клиент с таким именем не найден в этой подписке."
        remove_client "$token" "$uuid" ;;
      5)
        token=$(pick_sub) || exit 1
        jq -r '.clients[] | "\(.name) — \(.uuid)"' "$SUBS_DIR/$token" ;;
      6)
        token=$(pick_sub) || exit 1
        rm -f "$SUBS_DIR/$token" "$SUBS_WEBROOT/$token"; echo "Подписка удалена." ;;
    esac ;;
  *) die "Неизвестная команда" ;;
esac
SUBSCRIPTION_EOF
chmod +x /usr/local/bin/subscription

# Автоматическая персональная подписка для новых клиентов и удаление UUID из подписок.
cat << 'DIAG_EOF' > /usr/local/bin/xray-check
#!/bin/bash
source /usr/local/etc/xray/lib.sh
check_deps
load_keys
load_settings

echo "===== Проверка Xray ====="
echo "Адрес ссылок: $(get_ip)"
echo "TCP: $TCP_PORT"
echo "XHTTP: $XHTTP_PORT"
echo "Hysteria2 (UDP): $HY2_PORT"
echo "Fingerprint: $FP"
echo "UUID main: $MAIN_UUID"
echo "Public key: $PUBLIC_KEY"
echo "Short ID: $SHORT_ID"
echo ""

echo "-- Конфигурация --"
validate_xray_config && echo "OK: xray run -test"
echo ""
echo "-- Слушающие порты --"
ss -lntp 2>/dev/null | grep -E ":(${TCP_PORT}|${XHTTP_PORT})\b" || echo "Порты $TCP_PORT/$XHTTP_PORT не найдены в LISTEN."
if [[ -x /usr/local/bin/hysteria ]]; then
    ss -lnup 2>/dev/null | grep -E ":${HY2_PORT}\b" || echo "UDP-порт $HY2_PORT (Hysteria2) не найден в LISTEN."
fi
echo ""
echo "-- Служба --"
systemctl is-active xray && echo "OK: xray active" || systemctl status xray --no-pager -n 20
if [[ -x /usr/local/bin/hysteria ]]; then
    systemctl is-active hysteria-server >/dev/null 2>&1 \
        && echo "OK: hysteria-server active" \
        || systemctl status hysteria-server --no-pager -n 20
fi
echo ""
echo "-- Клиентские ссылки --"
gen_links "$MAIN_UUID" "main"
printf '%s\n' "$TCP_LINK"
printf '%s\n' "$XHTTP_LINK"
[[ -x /usr/local/bin/hysteria ]] && printf '%s\n' "$HY2_LINK"
DIAG_EOF
chmod +x /usr/local/bin/xray-check

cat << 'MENU_EOF' > /usr/local/bin/xray-menu
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
MENU_EOF
chmod +x /usr/local/bin/xray-menu

echo "Команды setcascade/unsetcascade/setmask/routingmode/disable_routing/renewgeo/subscription/setsubdomain/xray-check/xray-menu созданы"

# ── 7. Запуск службы ─────────────────────────────────────────────────────────
# config.json создавался напрямую через heredoc (не через mktemp+mv), но права
# фиксируем явно на случай нестандартного umask при первом запуске.
if id xray >/dev/null 2>&1; then
    chown root:xray "$CONFIG" 2>/dev/null || true
    chmod 640 "$CONFIG" || die "Не удалось установить права 640 на $CONFIG"
else
    chmod 600 "$CONFIG" || die "Не удалось установить права 600 на $CONFIG"
fi
chmod 600 "$KEYS" "$SETTINGS" 2>/dev/null || true

# Перед запуском Xray убеждаемся, что его порты свободны.
for check_port in "$TCP_PORT" "$XHTTP_PORT"; do
    if ss -lntp 2>/dev/null | grep -Eq ":${check_port}\b"; then
        echo "Порт $check_port уже занят:" >&2
        ss -lntp 2>/dev/null | grep -E ":${check_port}\b" >&2 || true
        die "Нельзя запустить Xray: порт $check_port уже используется. Освободите его или измените TCP_PORT/XHTTP_PORT."
    fi
done
if ss -lnup 2>/dev/null | grep -Eq ":${HY2_PORT}\b"; then
    echo "UDP-порт $HY2_PORT уже занят:" >&2
    ss -lnup 2>/dev/null | grep -E ":${HY2_PORT}\b" >&2 || true
    die "Нельзя запустить Hysteria2: UDP-порт $HY2_PORT уже используется. Освободите его или измените HY2_PORT."
fi

/usr/local/bin/hy2sync || die "Не удалось подготовить конфигурацию Hysteria2"
systemctl enable hysteria-server >/dev/null 2>&1
systemctl daemon-reload
systemctl restart hysteria-server || die "Не удалось запустить службу hysteria-server"

tries=0
while (( tries < 10 )); do
    systemctl is-active --quiet hysteria-server && break
    sleep 0.3
    ((tries++))
done
if ! systemctl is-active --quiet hysteria-server; then
    echo "Служба hysteria-server не запустилась. Последние строки журнала:" >&2
    journalctl -u hysteria-server -n 20 --no-pager >&2
    die "Служба hysteria-server не активна после установки"
fi

systemctl enable xray >/dev/null 2>&1
systemctl daemon-reload
systemctl restart xray || die "Не удалось запустить службу xray"

tries=0
while (( tries < 10 )); do
    systemctl is-active --quiet xray && break
    sleep 0.3
    ((tries++))
done
if ! systemctl is-active --quiet xray; then
    echo "Служба xray не запустилась. Последние строки журнала:" >&2
    journalctl -u xray -n 20 --no-pager >&2
    die "Служба xray не активна после установки"
fi

echo ""
echo "Xray-core успешно установлен."
echo "Hysteria2 успешно установлен (UDP-порт $HY2_PORT)."
mainuser

# ── 8. Файл-подсказка ────────────────────────────────────────────────────────
cat << HELP_EOF > "$HOME/help"

Команды для управления Xray (VLESS TCP-Reality + VLESS XHTTP-Reality):

    mainuser    - ссылки основного пользователя (TCP + XHTTP)
    newuser     - создать нового пользователя (сразу на обоих транспортах)
    rmuser      - удалить пользователя
    sharelink   - ссылки для существующего пользователя
    userlist    - список пользователей
    hy2sync     - пересобрать конфиг Hysteria2 из текущих пользователей
    hy2restart  - перезапустить Hysteria2 и показать статус/ссылку
    setcascade  - настроить каскад (proxy chaining) через внешний vless-сервер
    unsetcascade - отключить каскад
    setmask     - изменить SNI / shortId / fingerprint (маскировка)
    routingmode      - умный обход РФ (RU-трафик напрямую, остальное — в туннель)
    disable_routing  - отключить кастомную маршрутизацию (весь трафик — в туннель)
    renewgeo    - обновить geo-базы (geoip.dat / geosite.dat)
    subscription - управление подписками клиентов
    setsubdomain - настроить/сменить домен для ссылок подписки (можно и после установки)
    xray-check   - диагностика службы, портов, ключей и клиентских ссылок
    xray-menu    - интерактивное меню со всеми пунктами выше
    fixcert      - повторить выпуск сертификата и убрать insecure=1

Конфигурация:      $CONFIG
Ключи:              $KEYS
Настройки портов:   $SETTINGS
Адрес ссылок:        $SERVER_IP
Порты Xray:           TCP=$TCP_PORT  XHTTP=$XHTTP_PORT
Порт Hysteria2:       $HY2_PORT (UDP)
Порт HTTPS подписок:   $SUBS_PORT

Перезапуск ядра:    systemctl restart xray
Перезапуск Hysteria2: hy2restart
Статус:              systemctl status xray
Логи:                journalctl -u xray -f
Логи Hysteria2:       journalctl -u hysteria-server -f

HELP_EOF

if [[ -t 0 ]]; then
    echo "Запускаю меню управления..."
    /usr/local/bin/xray-menu
else
    echo "Подсказка сохранена в \$HOME/help. Наберите 'xray-menu' для интерактивного управления."
fi
