#!/usr/bin/env bash
set -euo pipefail

SAMPLE="${1:-./netplan-sample.yaml}"
TARGET="/etc/netplan/01-netcfg.yaml"

[[ $EUID -eq 0 ]] || { echo "Нужен root" >&2; exit 1; }
[[ -s "$SAMPLE" ]] || { echo "$SAMPLE не найден или пуст" >&2; exit 1; }

# Бэкап старых конфигов
BACKUP="/root/netplan-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
cp -a /etc/netplan/*.yaml "$BACKUP/" 2>/dev/null || true
echo "Бэкап: $BACKUP"

# Ставим конфиг и права (то, что ты делал вручную на шагах 6 и 11)
install -m 600 -o root -g root "$SAMPLE" "$TARGET"
echo "Конфиг установлен: $TARGET (600)"

# Размаскировать и запустить systemd-networkd (шаг 14)
systemctl unmask systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
systemctl enable --now systemd-networkd.service
systemctl enable --now systemd-networkd.socket 2>/dev/null || true
echo "systemd-networkd: запущен"

# Проверка синтаксиса (полезно, ничего не меняет)
netplan generate || { echo "Ошибка в конфиге, выходим" >&2; exit 1; }

# Применить. try — если есть TTY, иначе apply
if [[ -t 0 ]]; then
    netplan try --timeout 120
else
    netplan apply
fi

# Проверка связи перед тем, как трогать NM
sleep 2
GW=$(ip -4 route show default 2>/dev/null | awk '/via/ {print $3; exit}')
if [[ -n "$GW" ]] && ! ping -c 2 -W 2 "$GW" >/dev/null 2>&1; then
    echo "Нет пинга до $GW. NM не трогаем, проверь вручную." >&2
    exit 1
fi
echo "Связь через networkd есть (шлюз $GW отвечает)"

# Только теперь гасим NM (шаги 16–18)
systemctl stop NetworkManager 2>/dev/null || true
systemctl disable NetworkManager 2>/dev/null || true
systemctl mask NetworkManager 2>/dev/null || true

echo "Готово. Рекомендуется reboot для чистой проверки."
