#!/usr/bin/env bash

main() {
    set -euo pipefail

    # Сохраняем в текущий каталог, откуда запущен скрипт
    local OUT="./netplan-sample.yaml"
    local APPLY_URL="https://githubusercontent.com"

    # Проверка прав root (нужны для диагностики и дальнейшего перехода)
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Ошибка: запустите скрипт от имени root или через sudo." >&2
        exit 1
    fi

    # ==========================================================================
    # ЭТАП 1: Проверка ОС и окружения (Ubuntu Server 26.04 без GUI)
    # ==========================================================================
    if [[ ! -r /etc/os-release ]]; then
        echo "Ошибка: файл /etc/os-release не найден" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "26.04" ]] || \
       ! dpkg-query -W -f='${Status}' ubuntu-server 2>/dev/null | grep -q "ok installed"; then
        echo "Ошибка: требуется Ubuntu Server 26.04 (текущая: ${PRETTY_NAME:-неизвестно})" >&2
        exit 1
    fi

    if dpkg -l ubuntu-desktop 2>/dev/null | grep -q '^ii' || systemctl is-active --quiet gdm 2>/dev/null; then
        echo "Ошибка: обнаружена графическая оболочка рабочего стола, миграция отменена" >&2
        exit 1
    fi

    if ! command -v netplan >/dev/null 2>&1; then
        echo "Ошибка: утилита netplan не установлена в системе" >&2
        exit 1
    fi

    echo "✔ Проверка пройдена: трушный Ubuntu Server 26.04 готов к анализу сети."

    # ==========================================================================
    # ЭТАП 2: Определение текущего менеджера сети
    # ==========================================================================
    local CURRENT_MANAGER
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        CURRENT_MANAGER="NetworkManager"
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        CURRENT_MANAGER="systemd-networkd"
    else
        CURRENT_MANAGER="Другой / Не определен"
    fi

    # ==========================================================================
    # ЭТАП 3: Сбор текущих сетевых параметров
    # ==========================================================================
    local IFACE IPV4 IPV6 GW4 GW6 DNS DNS_FALLBACK
    IFACE=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -z "${IFACE:-}" ]] && IFACE=$(ip -6 -o route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -z "${IFACE:-}" ]]; then
        echo "Ошибка: не найден сетевой интерфейс с маршрутом по умолчанию" >&2
        exit 1
    fi

    IPV4=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}' || true)
    IPV6=$(ip -6 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}' || true)

    GW4=$(ip -4 route show default 2>/dev/null | awk '/via/ {print $3; exit}' || true)
    GW6=$(ip -6 route show default 2>/dev/null | awk '/via/ {print $3; exit}' || true)

    DNS=""
    DNS_FALLBACK=0
    if command -v resolvectl >/dev/null 2>&1; then
        DNS=$(
            {
                resolvectl dns "$IFACE" 2>/dev/null || true
                resolvectl dns 2>/dev/null | awk '
                    /^[^[:space:]]/ { if (line != "") print line; line = $0; next }
                    /^[[:space:]]/  { line = line " " $0; next }
                    END { if (line != "") print line }
                ' | grep '^Global:' || true
            } \
            | sed -E 's/^Link [0-9]+ \([^)]+\):[[:space:]]*//; s/^Global:[[:space:]]*//' \
            | tr ' ' '\n' \
            | sed 's/#.*//' \

            | grep -vE '^$|^127\.0\.0\.53$|^::1$' \
            | awk '!seen[$0]++' \
            | paste -sd, - \
            || true
        )
    fi

    if [[ -z "${DNS:-}" ]]; then
        DNS="1.1.1.1,8.8.8.8"
        DNS_FALLBACK=1
    fi

    # ==========================================================================
    # ЭТАП 4: Генерация YAML-конфига в текущий каталог
    # ==========================================================================
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

    # ==========================================================================
    # ЭТАП 5: Вывод сводки и интерактивный выбор
    # ==========================================================================
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

    # Интерактивное меню с чтением напрямую из /dev/tty (для работы через curl | bash)
    if [[ ! -r /dev/tty ]]; then
        echo "Терминал недоступен для интерактивного выбора. Выход без изменений."
        exit 0
    fi

    while true; do
        printf "Данные собраны, нажми 1 чтобы выйти без изменений настройки сети, или нажми 2 для запуска скрипта для установки netplan и перехода: "
        read -r -n 1 CHOICE </dev/tty
        echo

        case "$CHOICE" in
            1)
                echo "Выход без изменений. Конфиг остался в $(pwd)/netplan-sample.yaml"
                exit 0
                ;;
            2)
                echo "Загружаем и запускаем скрипт применения настроек..."
                curl -fsSL "$APPLY_URL" | bash
                exit $?
                ;;
            *)
                echo "Неверный ввод. Пожалуйста, нажмите 1 или 2."
                ;;
        esac
    done
}

main "$@"
