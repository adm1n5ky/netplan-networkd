#!/usr/bin/env bash
set -euo pipefail

OUT="${HOME}/netplan-sample.yaml"

# --- Интерфейс с default route ---
IFACE=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
[[ -z "${IFACE:-}" ]] && IFACE=$(ip -6 -o route show default 2>/dev/null | awk '{print $5; exit}')
if [[ -z "${IFACE:-}" ]]; then
    echo "Не найден интерфейс с default route" >&2
    exit 1
fi

# --- Адреса (global) ---
IPV4=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}' || true)
IPV6=$(ip -6 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}' || true)

# --- Шлюзы ---
GW4=$(ip -4 route show default 2>/dev/null | awk '/via/ {print $3; exit}' || true)
GW6=$(ip -6 route show default 2>/dev/null | awk '/via/ {print $3; exit}' || true)

# --- DNS: апстримы из Global, с разворотом переносов строк ---
DNS=""
DNS_FALLBACK=0
if command -v resolvectl >/dev/null 2>&1; then
    DNS=$(
        resolvectl dns 2>/dev/null \
            | awk '
                /^[^[:space:]]/ { if (line != "") print line; line = $0; next }
                /^[[:space:]]/  { line = line " " $0; next }
                END { if (line != "") print line }
            ' \
            | awk '/^Global:/ {sub(/^Global:[[:space:]]*/, ""); print; exit}' \
            | tr ' ' '\n' \
            | sed 's/#.*//' \
            | grep -vE '^$|^127\.0\.0\.53$' \
            | paste -sd, - \
            || true
    )
fi

if [[ -z "${DNS:-}" ]]; then
    DNS="1.1.1.1,8.8.8.8"
    DNS_FALLBACK=1
    echo "WARN: не удалось собрать DNS из resolvectl — подставлен fallback ${DNS}" >&2
fi

# --- Рендерер ---
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    RENDERER="NetworkManager"
else
    RENDERER="networkd"
fi

# --- YAML ---
{
    echo "network:"
    echo "  version: 2"
    echo "  renderer: ${RENDERER}"
    echo "  ethernets:"
    echo "    ${IFACE}:"
    echo "      dhcp4: no"
    echo "      dhcp6: no"
    echo "      addresses:"
    if [[ -n "${IPV4:-}" ]]; then echo "        - ${IPV4}"; fi
    if [[ -n "${IPV6:-}" ]]; then echo "        - ${IPV6}"; fi
    echo "      routes:"
    if [[ -n "${GW4:-}" ]]; then
        echo "        - to: default"
        echo "          via: ${GW4}"
        echo "          on-link: true"
    fi
    if [[ -n "${GW6:-}" ]]; then
        echo "        - to: \"::/0\""
        echo "          via: ${GW6}"
        echo "          on-link: true"
    fi
    if [[ -n "${DNS:-}" ]]; then
        echo "      nameservers:"
        echo "        addresses: [${DNS}]"
    fi
} > "$OUT"

# --- Лог ---
echo
echo "┌─────────────────────────────────────────────────────────────"
echo "│ Собрано со стенда"
echo "├─────────────────────────────────────────────────────────────"
printf "│ %-10s %s\n" "IFACE"    "$IFACE"
printf "│ %-10s %s\n" "IPv4"     "${IPV4:-—}"
printf "│ %-10s %s\n" "IPv6"     "${IPV6:-—}"
printf "│ %-10s %s\n" "GW IPv4"  "${GW4:-—}"
printf "│ %-10s %s\n" "GW IPv6"  "${GW6:-—}"
if [[ "$DNS_FALLBACK" == "1" ]]; then
    printf "│ %-10s %s  ⚠ FALLBACK\n" "DNS" "${DNS}"
else
    printf "│ %-10s %s\n" "DNS"      "${DNS}"
fi
printf "│ %-10s %s\n" "RENDERER" "$RENDERER"
echo "└─────────────────────────────────────────────────────────────"
echo

# --- Показ результата ---
echo "Сгенерированный образец: $OUT"
echo "─────────────────────────────────────────────────────────────"
cat "$OUT"
echo "─────────────────────────────────────────────────────────────"
