#!/bin/zsh
set -euo pipefail

# Отдельная связка ключей для подписи локальных сборок: в ней один самоподписанный
# сертификат и пароль, который знает только скрипт. Связку входа не трогает.
# Подпись с одним сертификатом даёт сборкам одно «требование», и разрешения
# системы переживают пересборку.
#
#   scripts/setup-build-keychain.sh [файл-с-паролем]

KEYCHAIN="${VOICEPASTE_BUILD_KEYCHAIN:-$HOME/Library/Keychains/voicepaste-local-signing.keychain-db}"
IDENTITY="VoicePaste Local Build"
SECRET_FILE="${1:-${VOICEPASTE_BUILD_KEYCHAIN_SECRET:-$HOME/.depo-lab/secrets/VOICEPASTE_BUILD_KEYCHAIN_PASSWORD_FILE}}"

if [[ -f "$KEYCHAIN" && ! -f "$SECRET_FILE" ]]; then
    print -u2 "Существующая связка не изменена: сначала восстановите её пароль через реестр секретов."
    exit 2
fi

if [[ -f "$KEYCHAIN" && -f "$SECRET_FILE" ]]; then
    if security unlock-keychain -p "$(cat "$SECRET_FILE")" "$KEYCHAIN" >/dev/null 2>&1; then
        print "Существующая подпись готова; сертификат не изменён."
        exit 0
    fi
    print -u2 "Служебная подпись не открывается сохранённым паролем; связка не изменена."
    exit 2
fi

mkdir -p "${SECRET_FILE:h}"
umask 077
PASSWORD="$(/usr/bin/openssl rand -hex 24)"
print -r -- "$PASSWORD" > "$SECRET_FILE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$IDENTITY/O=VoicePaste" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout "pass:$PASSWORD"

rm -f "$KEYCHAIN"
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

print "Готово: $KEYCHAIN, сертификат «$IDENTITY», пароль в $SECRET_FILE"
