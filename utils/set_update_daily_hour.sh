#!/usr/bin/env bash
# set_update_daily_hour.sh — view and update the scheduled hours for apt update and apt upgrade
#
# apt-daily (apt-get update)   runs TWICE daily: at the configured hour and 12 hours later.
# apt-daily-upgrade (apt-get upgrade) runs ONCE daily at its configured hour.
#
# Both are controlled via systemd timer drop-in overrides:
#   /etc/systemd/system/apt-daily.timer.d/override.conf
#   /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf
#
# Usage:
#   sudo ./set_update_daily_hour.sh
#
set -euo pipefail

UPDATE_OVERRIDE="/etc/systemd/system/apt-daily.timer.d/override.conf"
UPGRADE_OVERRIDE="/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf"

# --- Require root ---
if [[ $EUID -ne 0 ]]; then
    echo "[!] This script must be run as root (sudo)." >&2
    exit 1
fi

# --- Read current settings ---
read_current_update_hour() {
    if [[ -f "$UPDATE_OVERRIDE" ]]; then
        grep -oP '(?<=OnCalendar=\*-\*-\* )\d+' "$UPDATE_OVERRIDE" | head -1
    else
        echo "(not set — using systemd default)"
    fi
}

read_current_upgrade_hour() {
    if [[ -f "$UPGRADE_OVERRIDE" ]]; then
        grep -oP '(?<=OnCalendar=\*-\*-\* )\d+' "$UPGRADE_OVERRIDE" | head -1
    else
        echo "(not set — using systemd default)"
    fi
}

# --- Get system timezone ---
SYSTEM_TZ=$(timedatectl | awk '/Time zone:/ {print $3}')

# --- Print current settings ---
echo ""
echo "  Current scheduled hours (timezone: $SYSTEM_TZ)"
echo "  -----------------------"
CURRENT_UPDATE_HOUR=$(read_current_update_hour)
CURRENT_UPDATE_HOUR_2=""
if [[ "$CURRENT_UPDATE_HOUR" =~ ^[0-9]+$ ]]; then
    CURRENT_UPDATE_HOUR_2=$(( (CURRENT_UPDATE_HOUR + 12) % 24 ))
    echo "  apt-get update  (apt-daily)         : ${CURRENT_UPDATE_HOUR}:00 and ${CURRENT_UPDATE_HOUR_2}:00"
else
    echo "  apt-get update  (apt-daily)         : $CURRENT_UPDATE_HOUR"
fi

CURRENT_UPGRADE_HOUR=$(read_current_upgrade_hour)
if [[ "$CURRENT_UPGRADE_HOUR" =~ ^[0-9]+$ ]]; then
    echo "  apt-get upgrade (apt-daily-upgrade) : ${CURRENT_UPGRADE_HOUR}:00"
else
    echo "  apt-get upgrade (apt-daily-upgrade) : $CURRENT_UPGRADE_HOUR"
fi

echo ""

# --- Prompt for new update hour ---
while true; do
    DEFAULT_UPDATE="${CURRENT_UPDATE_HOUR:-10}"
    [[ "$DEFAULT_UPDATE" =~ ^[0-9]+$ ]] || DEFAULT_UPDATE="10"
    read -rp "  New hour for apt-get update (0-23) [${DEFAULT_UPDATE}]: " NEW_UPDATE_HOUR
    NEW_UPDATE_HOUR="${NEW_UPDATE_HOUR:-$DEFAULT_UPDATE}"
    if [[ "$NEW_UPDATE_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
        break
    else
        echo "  [!] Invalid hour — please enter a number between 0 and 23."
    fi
done

NEW_UPDATE_HOUR_2=$(( (NEW_UPDATE_HOUR + 12) % 24 ))

# --- Prompt for new upgrade hour ---
while true; do
    DEFAULT_UPGRADE="${CURRENT_UPGRADE_HOUR:-$(( (NEW_UPDATE_HOUR + 1) % 24 ))}"
    [[ "$DEFAULT_UPGRADE" =~ ^[0-9]+$ ]] || DEFAULT_UPGRADE=$(( (NEW_UPDATE_HOUR + 1) % 24 ))
    read -rp "  New hour for apt-get upgrade (0-23) [${DEFAULT_UPGRADE}]: " NEW_UPGRADE_HOUR
    NEW_UPGRADE_HOUR="${NEW_UPGRADE_HOUR:-$DEFAULT_UPGRADE}"
    if [[ "$NEW_UPGRADE_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
        break
    else
        echo "  [!] Invalid hour — please enter a number between 0 and 23."
    fi
done

# --- Apply ---
echo ""
echo "  Applying ..."

mkdir -p "$(dirname "$UPDATE_OVERRIDE")"
# The empty "OnCalendar=" resets the packaged schedule; without it the default timer (~6am) still fires as well.
printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* %s,%s:00\nRandomizedDelaySec=60m\n' \
    "$NEW_UPDATE_HOUR" "$NEW_UPDATE_HOUR_2" > "$UPDATE_OVERRIDE"

mkdir -p "$(dirname "$UPGRADE_OVERRIDE")"
printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* %s:00\nRandomizedDelaySec=60m\n' \
    "$NEW_UPGRADE_HOUR" > "$UPGRADE_OVERRIDE"

systemctl daemon-reload
systemctl restart apt-daily.timer
systemctl restart apt-daily-upgrade.timer

# --- Verify ---
echo ""
echo "  Verified scheduled hours (timezone: $SYSTEM_TZ)"
echo "  ------------------------"
VERIFIED_UPDATE=$(read_current_update_hour)
VERIFIED_UPGRADE=$(read_current_upgrade_hour)

if [[ "$VERIFIED_UPDATE" == "$NEW_UPDATE_HOUR" ]]; then
    echo "  apt-get update  (apt-daily)         : ${NEW_UPDATE_HOUR}:00 and ${NEW_UPDATE_HOUR_2}:00  [OK]"
else
    echo "  apt-get update  (apt-daily)         : $VERIFIED_UPDATE  [!] expected $NEW_UPDATE_HOUR"
fi

if [[ "$VERIFIED_UPGRADE" == "$NEW_UPGRADE_HOUR" ]]; then
    echo "  apt-get upgrade (apt-daily-upgrade) : ${NEW_UPGRADE_HOUR}:00  [OK]"
else
    echo "  apt-get upgrade (apt-daily-upgrade) : $VERIFIED_UPGRADE  [!] expected $NEW_UPGRADE_HOUR"
fi

echo ""
echo "  Next scheduled runs:"
systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --no-pager 2>/dev/null || true
