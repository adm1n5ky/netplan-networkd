#!/usr/bin/env bash

main() {
    set -euo pipefail

    local SAMPLE="./netplan-sample.yaml"
    local TARGET_DIR="/etc/netplan"
    local TARGET_FILE="${TARGET_DIR}/01-netcfg.yaml"
    local BACKUP_DIR="/root/netplan-backup-$(date +%Y%m%d-%H%M%S)"

    # 0. Проверка прав root, наличия netplan и сгенерированного образца
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Ошибка: запустите apply.sh от имени root." >&2
        exit 1
    fi

    if ! command -v netplan >/dev/null 2>&1; then
        echo ">>> Утилита netplan не найдена. Устанавливаем netplan.io..."
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq netplan.io
    fi

    if [[ ! -s "$SAMPLE" ]]; then
        echo "Ошибка: файл $SAMPLE не найден или пуст. Сначала запустите сбор данных." >&2
        exit 1
    fi

    echo ">>> Начинаем безопасный переход на systemd-networkd..."

    # Очищаем старые .bak от предыдущих неудачных попыток, если остались
    rm -f "${TARGET_DIR}"/*.yaml.bak

    # 1. Создаем резервную копию всего каталога /etc/netplan
    mkdir -p "$BACKUP_DIR"
    if ls "${TARGET_DIR}"/*.yaml >/dev/null 2>&1; then
        cp -a "${TARGET_DIR}"/*.yaml "$BACKUP_DIR/"
        echo "✔ Бэкап старых конфигов сохранен в: $BACKUP_DIR"

        for f in "${TARGET_DIR}"/*.yaml; do
            mv "$f" "${f}.bak"
        done
    else
        echo "ℹ Старых .yaml файлов в $TARGET_DIR не обнаружено."
    fi

    # 2. Устанавливаем базовый конфиг 01-netcfg.yaml с правами 600
    cp "$SAMPLE" "$TARGET_FILE"
    chown root:root "$TARGET_FILE"
    chmod 600 "$TARGET_FILE"
    echo "✔ Базовый конфиг установлен: $TARGET_FILE (права 600)"

    # 3. Предварительная проверка синтаксиса
    echo ">>> Проверяем синтаксис конфигурации..."
    if ! netplan generate; then
        echo "ОШИБКА: netplan generate обнаружил проблему в конфиге! Откатываем изменения..." >&2
        rm -f "$TARGET_FILE"
        for f in "${TARGET_DIR}"/*.yaml.bak; do
            [[ -e "$f" ]] && mv "$f" "${f%.bak}"
        done
        exit 1
    fi
    echo "✔ Синтаксис Netplan валиден."

    # 4. Размаскируем и включаем systemd-networkd до применения настроек
    systemctl unmask systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service >/dev/null 2>&1 || true
    systemctl enable systemd-networkd.service systemd-networkd.socket >/dev/null 2>&1 || true
    systemctl start systemd-networkd.service

    # 5. Запускаем фоновый таймер отката на 120 секунд (страховка на случай потери SSH)
    (
        sleep 120
        rm -f "$TARGET_FILE"
        for f in "${TARGET_DIR}"/*.yaml.bak; do
            [[ -e "$f" ]] && mv "$f" "${f%.bak}"
        done
        systemctl unmask NetworkManager >/dev/null 2>&1 || true
        systemctl start NetworkManager >/dev/null 2>&1 || true
        netplan apply >/dev/null 2>&1 || true
    ) >/dev/null 2>&1 &
    local ROLLBACK_PID=$!

    # Гарантируем, что при штатном выходе или ошибке мы не оставим висящих процессов
    cleanup_rollback() {
        kill "$ROLLBACK_PID" 2>/dev/null || true
    }

    # 6. Применяем новую конфигурацию напрямую
    echo ">>> Применяем конфигурацию через netplan apply (страховка отката запущена на 120 сек)..."
    netplan apply
    sleep 2

    # 7. Проверяем доступность шлюза
    local GW4
    GW4=$(ip -4 route show default 2>/dev/null | awk '/via/ {print $3; exit}' || true)
    if [[ -n "$GW4" ]] && ! ping -c 2 -W 2 "$GW4" >/dev/null 2>&1; then
        echo "ОШИБКА: шлюз $GW4 не пингуется! Запускаем немедленный откат..." >&2
        cleanup_rollback
        rm -f "$TARGET_FILE"
        for f in "${TARGET_DIR}"/*.yaml.bak; do
            [[ -e "$f" ]] && mv "$f" "${f%.bak}"
        done
        netplan apply || true
        exit 1
    fi
    echo "✔ Шлюз $GW4 отвечает, связь стабильна."

    # 8. Безопасно останавливаем и отключаем NetworkManager
    if systemctl is-active --quiet NetworkManager 2>/dev/null || systemctl is-enabled --quiet NetworkManager 2>/dev/null; then
        echo ">>> Отключаем службу NetworkManager..."
        systemctl stop NetworkManager 2>/dev/null || true
        systemctl disable NetworkManager 2>/dev/null || true
        systemctl mask NetworkManager 2>/dev/null || true
        echo "✔ NetworkManager остановлен и отключен."
    fi

    # Повторная проверка связи уже без NetworkManager
    if [[ -n "$GW4" ]] && ! ping -c 2 -W 2 "$GW4" >/dev/null 2>&1; then
        echo "ОШИБКА: связь пропала после остановки NetworkManager! Откатываемся..." >&2
        cleanup_rollback
        rm -f "$TARGET_FILE"
        for f in "${TARGET_DIR}"/*.yaml.bak; do
            [[ -e "$f" ]] && mv "$f" "${f%.bak}"
        done
        systemctl unmask NetworkManager 2>/dev/null || true
        systemctl enable --now NetworkManager 2>/dev/null || true
        netplan apply || true
        exit 1
    fi

    # 9. Отменяем таймер отката и удаляем .bak файлы, так как миграция прошла успешно
    cleanup_rollback
    rm -f "${TARGET_DIR}"/*.yaml.bak

    # 10. Итог
    echo
    echo "=============================================================="
    echo "✔ МИГРАЦИЯ УСПЕШНО ЗАВЕРШЕНА"
    echo "--------------------------------------------------------------"
    echo "Активный менеджер : $(systemctl is-active systemd-networkd)"
    echo "NetworkManager    : $(systemctl is-active NetworkManager 2>/dev/null || echo 'inactive')"
    echo "Базовый конфиг    : $TARGET_FILE"
    echo "Резервная копия   : $BACKUP_DIR"
    echo "=============================================================="
    netplan status 2>/dev/null || ip -br a
}

main "$@"
