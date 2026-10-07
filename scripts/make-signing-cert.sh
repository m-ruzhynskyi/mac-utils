#!/bin/bash
# Один раз создаёт самоподписанный сертификат «Mac Utils Signing» для подписи кода.
# С постоянной подписью macOS запоминает разрешения (Универсальный доступ,
# Запись экрана) и не сбрасывает их после каждой сборки и автообновления.
#
#   ./scripts/make-signing-cert.sh            — сертификат в связку ключей (для локальной сборки)
#   ./scripts/make-signing-cert.sh owner/repo — плюс секреты SIGNING_P12 и SIGNING_PASSWORD
#                                               в репозиторий GitHub (нужен gh, `gh auth login`)
set -euo pipefail

NAME="Mac Utils Signing"
REPO="${1:-}"
OPENSSL=/usr/bin/openssl   # системный LibreSSL: его .p12 понимает `security import`
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "Сертификат «$NAME» уже есть в связке ключей."
    if [[ -z "$REPO" ]]; then exit 0; fi
    echo "Для секретов GitHub нужен новый .p12 — удалите старый сертификат в «Связке ключей» и запустите скрипт снова." >&2
    exit 1
fi

cat > "$DIR/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

PASSWORD="$($OPENSSL rand -hex 16)"
$OPENSSL req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -config "$DIR/cert.cnf"
$OPENSSL pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
    -name "$NAME" -out "$DIR/signing.p12" -passout "pass:$PASSWORD"

security import "$DIR/signing.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASSWORD" -T /usr/bin/codesign
echo "Сертификат «$NAME» добавлен в связку ключей «Вход»."

if [[ -n "$REPO" ]]; then
    base64 -i "$DIR/signing.p12" | gh secret set SIGNING_P12 --repo "$REPO"
    printf '%s' "$PASSWORD" | gh secret set SIGNING_PASSWORD --repo "$REPO"
    echo "Секреты SIGNING_P12 и SIGNING_PASSWORD сохранены в $REPO."
fi
