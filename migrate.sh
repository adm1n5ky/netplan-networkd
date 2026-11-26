#!/usr/bin/env bash

main() {
    set -euo pipefail

    local OUT="./netplan-sample.yaml"

    # --- Проверка root ---
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Ошибка: запустите скрипт от имени root или через sudo." >&2
        exit 1
    fi

    # --- Проверка ОС (Ubuntu 26.04, без десктопа) ---
    if [[ ! -r /etc/os-release ]]; then
        echo "Ошибка: файл /etc/os-release не найден" >&2
        exit 1
    fi
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "26.04" ]]; then
        echo "Ошибка: требуется Ubuntu 26.04 (текущая: ${PRETTY_NAME:-неизвестно})" >&2
        exit 1
    fi

    if dpkg -l ubuntu-desktop 2>/dev/null | grep -q '^ii' || systemctl is-active --quiet gdm 2>/dev/null; then
        echo "Ошибка: обнаружена графическая оболочка, миграция отменена" >&2
        exit 1
    fi

    if ! command -v netplan >/dev/null 2>&1; then
        echo "Ошибка: утилита netplan не установлена" >&2
        exit 1
    fi

    echo "✔ Проверка пройдена: Ubuntu Server 26.04 готов к анализу сети."

    # --- Текущий менеджер ---
    local CURRENT_MANAGER
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        CURRENT_MANAGER="NetworkManager"
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        CURRENT_MANAGER="systemd-networkd"
    else
        CURRENT_MANAGER="Другой / Не определен"
    fi

    # --- Сбор сети ---
    local IFACE IPV4 IPV6 GW4 GW6 DNS DNS_FALLBACK
    IFACE=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -z "${IFACE:-}" ]] && IFACE=$(ip -6 -o route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -z "${IFACE:-}" ]]; then
        echo "Ошибка: не найден интерфейс с маршрутом по умолчанию" >&2
        exit 1
    fi

    IPV4=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}' || true)
    IPV6=$(ip -6 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}' || true)
    GW4=$(ip -4 route show default 2>/dev/null | awk '/via/ {print $3; exit}' || true)
    GW6=$(ip -6 route show default 2>/dev/null | awk '/via/ {print $3; exit}' || true)

    # --- DNS (только Global, без stub 127.0.0.53) ---
    DNS=""
    DNS_FALLBACK=0
    if command -v resolvectl >/dev/null 2>&1; then
        DNS=$(resolvectl dns 2>/dev/null \
            | awk '/^[^[:space:]]/ { if (line != "") print line; line = $0; next }
                   /^[[:space:]]/  { line = line " " $0; next }
                   END { if (line != "") print line }' \
            | awk '/^Global:/ {sub(/^Global:[[:space:]]*/, ""); print; exit}' \
            | tr ' ' '\n' \
            | sed 's/#.*//' \
            | grep -vE '^$|^127\.0\.0\.53$|^::1$' \
            | paste -sd, - \
            || true)
    fi
    if [[ -z "${DNS:-}" ]]; then
        DNS="1.1.1.1,8.8.8.8"
        DNS_FALLBACK=1
    fi

    # --- Генерация YAML ---
    {
        echo "network:"
        echo "  version: 2"
        echo "  renderer: networkd"
        echo "  ethernets:"
        echo "    ${IFACE}:"
        echo "      dhcp4: false"
        echo "      dhcp6: false"

        if [[ -n "${IPV4:-}" || -n "${IPV6:-}" ]]; then
            echo "      addresses:"
            [[ -n "${IPV4:-}" ]] && echo "        - ${IPV4}"
            [[ -n "${IPV6:-}" ]] && echo "        - ${IPV6}"
        fi

        if [[ -n "${GW4:-}" || -n "${GW6:-}" ]]; then
            echo "      routes:"
            if [[ -n "${GW4:-}" ]]; then
                echo "        - to: default"
                echo "          via: ${GW4}"
                echo "          on-link: true"
            fi
            if [[ -n "${GW6:-}" ]]; then
                echo "        - to: \"::/0\""
                echo "          via: ${GW6}"
                # on-link для IPv6 нужен только если шлюз НЕ link-local
                if [[ ! "${GW6}" =~ ^fe80: ]]; then
                    echo "          on-link: true"
                fi
            fi
        fi

        if [[ -n "${DNS:-}" ]]; then
            echo "      nameservers:"
            echo "        addresses: [${DNS}]"
        fi
    } > "$OUT"

    # --- Сводка ---
    echo
    echo "┌─────────────────────────────────────────────────────────────"
    echo "│ Диагностика текущей сети"
    echo "├─────────────────────────────────────────────────────────────"
    printf "│ %-14s %s\n" "УПРАВЛЕНИЕ"   "$CURRENT_MANAGER"
    printf "│ %-14s %s\n" "ИНТЕРФЕЙС"    "$IFACE"
    printf "│ %-14s %s\n" "IPv4"         "${IPV4:-—}"
    printf "│ %-14s %s\n" "IPv6"         "${IPV6:-—}"
    printf "│ %-14s %s\n" "ШЛЮЗ IPv4"    "${GW4:-—}"
    printf "│ %-14s %s\n" "ШЛЮЗ IPv6"    "${GW6:-—}"
    if [[ "$DNS_FALLBACK" == "1" ]]; then
        printf "│ %-14s %s  ⚠ FALLBACK\n" "DNS" "${DNS}"
    else
        printf "│ %-14s %s\n" "DNS"      "${DNS}"
    fi
    echo "└─────────────────────────────────────────────────────────────"
    echo
    echo "Сгенерированный образец сохранен в: $(pwd)/netplan-sample.yaml"
    echo "─────────────────────────────────────────────────────────────"
    cat "$OUT"
    echo "─────────────────────────────────────────────────────────────"
    echo
    echo "Дальнейшие шаги (выполнять вручную, с открытой второй SSH-сессией):"
    echo
    echo "  1. Бэкап:"
    echo "     sudo mkdir -p /root/netplan-backup && sudo cp -a /etc/netplan/*.yaml /root/netplan-backup/"
    echo
    echo "  2. Установить конфиг с правами 600:"
    echo "     sudo install -m 600 ./netplan-sample.yaml /etc/netplan/01-netcfg.yaml"
    echo
    echo "  3. Проверить синтаксис:"
    echo "     sudo netplan generate"
    echo
    echo "  4. Размаскировать networkd (но НЕ запускать вручную):"
    echo "     sudo systemctl unmask systemd-networkd.service systemd-networkd.socket"
    echo
    echo "  5. Применить через try (netplan сам поднимет networkd):"
    echo "     sudo netplan try --timeout 120"
    echo
    echo "  6. Проверить связь (НЕ пингуй шлюз — в облаке он может не отвечать на ICMP):"
    echo "     ping -c 2 1.1.1.1"
    echo "     ping -c 2 ya.ru"
    echo
    echo "  7. Только после успешной проверки — погасить NetworkManager:"
    echo "     sudo systemctl stop NetworkManager && sudo systemctl disable NetworkManager && sudo systemctl mask NetworkManager"
    echo
    echo "  8. Перезагрузиться для чистой проверки:"
    echo "     sudo reboot"
}

main "$@"
