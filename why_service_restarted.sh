#!/usr/bin/env bash
# why_service_restarted.sh — Investigate why a systemd service was restarted
# Usage: ./why_service_restarted.sh <service> [YYYY-MM-DD] [HH:MM:SS]
#
# Examples:
#   ./why_service_restarted.sh wazuh-agent
#   ./why_service_restarted.sh nginx 2026-05-28
#   ./why_service_restarted.sh mysql 2026-05-28 06:46:00

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Args ───────────────────────────────────────────────────────────────────────
SERVICE="${1:-}"
if [[ -z "$SERVICE" ]]; then
  echo "Usage: $0 <service-name> [YYYY-MM-DD] [HH:MM:SS]"
  echo "  e.g. $0 wazuh-agent"
  echo "  e.g. $0 nginx 2026-05-28"
  echo "  e.g. $0 mysql 2026-05-28 06:46:00"
  exit 1
fi

SERVICE="${SERVICE%.service}"
TARGET_DATE="${2:-}"
TARGET_TIME="${3:-}"

# ── Helpers ────────────────────────────────────────────────────────────────────
section() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
info()    { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
found()   { echo -e "  ${RED}►${RESET}  $*"; }

# ── 1. Find the restart event ──────────────────────────────────────────────────
section "Finding restart events for: $SERVICE"

SINCE_ARGS=()
if [[ -n "$TARGET_DATE" && -n "$TARGET_TIME" ]]; then
  EPOCH=$(date -d "$TARGET_DATE $TARGET_TIME" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$TARGET_DATE $TARGET_TIME" +%s)
  SINCE=$(date -d "@$((EPOCH - 120))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((EPOCH - 120))" '+%Y-%m-%d %H:%M:%S')
  UNTIL=$(date -d "@$((EPOCH + 120))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((EPOCH + 120))" '+%Y-%m-%d %H:%M:%S')
  SINCE_ARGS=(--since "$SINCE" --until "$UNTIL")
elif [[ -n "$TARGET_DATE" ]]; then
  SINCE_ARGS=(--since "$TARGET_DATE 00:00:00" --until "$TARGET_DATE 23:59:59")
fi

# Get stop events — deduplicate so each restart appears once
STOP_LINES=$(journalctl -u "${SERVICE}.service" "${SINCE_ARGS[@]}" --no-pager -o short-iso 2>/dev/null \
  | grep -E "Stopped [^(]|Deactivated successfully" \
  | grep -v "Stopping" \
  | tail -20 || true)

if [[ -z "$STOP_LINES" ]]; then
  warn "No stop events found for '$SERVICE' in the given time range."
  warn "Showing last 5 journal entries instead:"
  journalctl -u "${SERVICE}.service" --no-pager -n 5 2>/dev/null || true
  exit 0
fi

echo "$STOP_LINES" | while IFS= read -r line; do found "$line"; done

# Extract timestamp of most recent stop event
STOP_TS=$(echo "$STOP_LINES" | tail -1 | grep -oP '^\S+' || true)
if [[ -z "$STOP_TS" ]]; then
  warn "Could not parse timestamp from stop event."
  exit 1
fi

# Normalise ISO timestamp for date -d
STOP_TS_NORM=$(echo "$STOP_TS" | sed 's/T/ /' | sed 's/+[0-9:]*$//' | sed 's/Z$//')
STOP_EPOCH=$(date -d "$STOP_TS_NORM" +%s 2>/dev/null \
  || date -j -f "%Y-%m-%d %H:%M:%S" "$STOP_TS_NORM" +%s 2>/dev/null \
  || echo "")

# Compute analysis windows
if [[ -n "$STOP_EPOCH" ]]; then
  WINDOW_START=$(date -d "@$((STOP_EPOCH - 15))"  '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((STOP_EPOCH - 15))"  '+%Y-%m-%d %H:%M:%S')
  WINDOW_END=$(date   -d "@$((STOP_EPOCH + 5))"   '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((STOP_EPOCH + 5))"   '+%Y-%m-%d %H:%M:%S')
  DPKG_SINCE=$(date -d "@$((STOP_EPOCH - 300))"   '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((STOP_EPOCH - 300))" '+%Y-%m-%d %H:%M:%S')
  DPKG_UNTIL=$(date -d "@$((STOP_EPOCH + 10))"    '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((STOP_EPOCH + 10))"  '+%Y-%m-%d %H:%M:%S')
fi

info "Analysing stop at: $STOP_TS"

# ── 1b. Detect mass-simultaneous-stop (daemon-reexec cascade fingerprint) ──────
# When systemd reexecs, many unrelated services stop within the same second.
# Count distinct services that stopped within ±3s of our event — if ≥4, it's
# almost certainly a cascade rather than an isolated restart.
if [[ -n "$STOP_EPOCH" ]]; then
  MASS_START=$(date -d "@$((STOP_EPOCH - 3))"  '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((STOP_EPOCH - 3))"  '+%Y-%m-%d %H:%M:%S')
  MASS_END=$(date   -d "@$((STOP_EPOCH + 3))"  '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((STOP_EPOCH + 3))"  '+%Y-%m-%d %H:%M:%S')
  MASS_SERVICES=$(journalctl --since "$MASS_START" --until "$MASS_END" --no-pager -o short-iso 2>/dev/null \
    | grep -E "Deactivated successfully|Stopped [^(]" \
    | grep -oP 'systemd\[1\]: \K\S+(?=\.service|\.timer)' \
    | sort -u || true)
  MASS_COUNT=$(echo "$MASS_SERVICES" | grep -c . 2>/dev/null || true); MASS_COUNT=$(( MASS_COUNT + 0 ))

  if [[ "$MASS_COUNT" -ge 4 ]]; then
    warn "MASS STOP: $MASS_COUNT services stopped within ±3s — likely a daemon-reexec cascade."
    echo "$MASS_SERVICES" | tr '\n' ' ' | fold -s -w 70 | while IFS= read -r line; do echo "    $line"; done
    echo ""
    # Widen to ±2min to find the reexec even if it fell just outside the normal window
    WIDE_START=$(date -d "@$((STOP_EPOCH - 120))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((STOP_EPOCH - 120))" '+%Y-%m-%d %H:%M:%S')
    WIDE_REEXEC=$(journalctl --since "$WIDE_START" --until "$MASS_END" --no-pager -o short-iso 2>/dev/null \
      | grep -i "reexecut\|daemon-reexec" || true)
    if [[ -n "$WIDE_REEXEC" ]]; then
      found "daemon-reexec confirmed in ±2min window:"
      echo "$WIDE_REEXEC" | head -3 | while IFS= read -r line; do echo "    $line"; done
    else
      warn "No reexec found even in ±2min — may be a reboot or shutdown rather than reexec."
    fi
  fi
fi

# ── 2. Check for systemd daemon-reexec (library upgrade trigger) ──────────────
section "Checking for systemd daemon-reexec (library upgrade)"

if [[ -n "$STOP_EPOCH" ]]; then
  REEXEC=$(journalctl --since "$WINDOW_START" --until "$WINDOW_END" --no-pager -o short-iso 2>/dev/null \
    | grep -i "reexecut\|daemon-reexec" || true)
  if [[ -n "$REEXEC" ]]; then
    found "systemd daemon-reexec detected — systemd restarted itself in-place."
    echo "$REEXEC" | head -5 | while IFS= read -r line; do echo "    $line"; done
    REEXEC_PID=$(echo "$REEXEC" | grep -oP "PID \K[0-9]+" | head -1 || true)
    if [[ -n "$REEXEC_PID" ]]; then
      REEXEC_CALLER=$(journalctl --since "$WINDOW_START" --until "$WINDOW_END" --no-pager -o short-iso 2>/dev/null \
        | grep "\[$REEXEC_PID\]\|pid=$REEXEC_PID\b" | head -3 || true)
      if [[ -n "$REEXEC_CALLER" ]]; then
        found "Reexec triggered by:"
        echo "$REEXEC_CALLER" | while IFS= read -r line; do echo "    $line"; done
      fi
    fi
    echo ""
    warn "Root cause: a shared library systemd links against (e.g. libgcrypt, libssl) was upgraded"
    warn "by unattended-upgrades, causing systemd to reexec and restart dependent services."
  else
    info "No daemon-reexec found in the ±15s window."
  fi
fi

# ── 3. Check unattended-upgrades / apt activity ───────────────────────────────
section "Checking apt / unattended-upgrades activity"

if [[ -n "$STOP_EPOCH" ]]; then
  if [[ -f /var/log/dpkg.log ]]; then
    DPKG=$(awk -v s="$DPKG_SINCE" -v e="$DPKG_UNTIL" '$0 >= s && $0 <= e' /var/log/dpkg.log \
      | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} (upgrade|install|configure)" || true)
    if [[ -n "$DPKG" ]]; then
      found "Packages changed in the 5 minutes before / 10s after restart:"
      echo "$DPKG" | while IFS= read -r line; do echo "    $line"; done
    else
      info "No dpkg upgrades found in the 5-minute window before restart."
    fi
  fi

  if [[ -f /var/log/unattended-upgrades/unattended-upgrades.log ]]; then
    UU_DATE="${STOP_TS:0:10}"
    UU=$(grep "$UU_DATE" /var/log/unattended-upgrades/unattended-upgrades.log \
      | grep -i "upgrade\|install\|error\|reboot" | tail -10 || true)
    if [[ -n "$UU" ]]; then
      found "Unattended-upgrades activity on that day:"
      echo "$UU" | while IFS= read -r line; do echo "    $line"; done
    fi
  fi
fi

# ── 4. Check needrestart ───────────────────────────────────────────────────────
section "Checking needrestart activity"

if [[ -n "$STOP_EPOCH" ]]; then
  NEEDRESTART=$(journalctl --since "$WINDOW_START" --until "$WINDOW_END" --no-pager -o short-iso 2>/dev/null \
    | grep -i "needrestart\|restart.*service\|service.*restart" | grep -iv "^--" || true)
  if [[ -n "$NEEDRESTART" ]]; then
    found "needrestart or service restart request detected:"
    echo "$NEEDRESTART" | head -10 | while IFS= read -r line; do echo "    $line"; done
  else
    info "No needrestart activity detected."
  fi
fi

# ── 5. Check for manual / scripted systemctl calls ────────────────────────────
section "Checking for manual or scripted restart"

if [[ -n "$STOP_EPOCH" ]]; then
  MANUAL_START=$(date -d "@$((STOP_EPOCH - 30))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((STOP_EPOCH - 30))" '+%Y-%m-%d %H:%M:%S')
  MANUAL_END=$(date   -d "@$((STOP_EPOCH + 10))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((STOP_EPOCH + 10))" '+%Y-%m-%d %H:%M:%S')

  AUDIT_CMD=$(journalctl --since "$MANUAL_START" --until "$MANUAL_END" --no-pager -o short-iso 2>/dev/null \
    | grep -i "USER_CMD\|SYSCALL.*systemctl\|comm=\"systemctl\"" | grep -iv "^--" || true)
  if [[ -n "$AUDIT_CMD" ]]; then
    found "Audit USER_CMD (sudo) event detected:"
    echo "$AUDIT_CMD" | head -5 | while IFS= read -r line; do echo "    $line"; done
  fi

  SUDO=""
  for LOG in /var/log/auth.log /var/log/secure; do
    if [[ -f "$LOG" ]]; then
      _SUDO=$(awk -v s="$MANUAL_START" -v e="$MANUAL_END" '$0 >= s && $0 <= e' "$LOG" \
        | grep -i "systemctl\|$SERVICE" || true)
      if [[ -n "$_SUDO" ]]; then
        found "sudo/auth activity ($LOG):"
        echo "$_SUDO" | head -5 | while IFS= read -r line; do echo "    $line"; done
        SUDO="$_SUDO"
      fi
    fi
  done

  SYSTEMD_STOP=$(journalctl --since "$MANUAL_START" --until "$MANUAL_END" --no-pager -o verbose 2>/dev/null \
    | grep -A2 -i "systemctl.*${SERVICE}\|UNIT=${SERVICE}" | head -20 || true)
  if [[ -n "$SYSTEMD_STOP" ]]; then
    found "systemd unit control event:"
    echo "$SYSTEMD_STOP" | head -10 | while IFS= read -r line; do echo "    $line"; done
  fi

  if [[ -z "$AUDIT_CMD" && -z "$SUDO" ]]; then
    info "No manual systemctl restart detected in auth/audit logs."
  fi
fi

# ── 6. Check certbot / logrotate / cron ───────────────────────────────────────
# Only flag events that are causative (starting/running), not collateral
# timer deactivations which happen during any mass-stop cascade.
section "Checking certbot / logrotate / cron"

if [[ -n "$STOP_EPOCH" ]]; then
  CRON_START=$(date -d "@$((STOP_EPOCH - 60))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((STOP_EPOCH - 60))" '+%Y-%m-%d %H:%M:%S')

  # Certbot: match service starting/running, not timer deactivation
  CERTBOT=$(journalctl --since "$CRON_START" --until "$WINDOW_END" --no-pager -o short-iso 2>/dev/null \
    | grep -i "certbot\|letsencrypt\|acme\|cert.renew" \
    | grep -iv "timer.*Deactivat\|Deactivat.*timer\|Stopped certbot.timer\|certbot.timer:.*Deactivat" \
    || true)
  if [[ -n "$CERTBOT" ]]; then
    found "Certbot / Let's Encrypt activity detected (causative):"
    echo "$CERTBOT" | head -5 | while IFS= read -r line; do echo "    $line"; done
  else
    info "No certbot activity detected."
  fi

  # Logrotate: match the logrotate process itself, not incidental mentions
  LOGROTATE=$(journalctl --since "$CRON_START" --until "$WINDOW_END" --no-pager -o short-iso 2>/dev/null \
    | grep -i "logrotate\|postrotate" \
    | grep -iv "timer.*Deactivat\|Deactivat.*timer\|Stopped logrotate.timer\|logrotate.timer:.*Deactivat" \
    || true)
  if [[ -n "$LOGROTATE" ]]; then
    found "logrotate activity detected:"
    echo "$LOGROTATE" | head -5 | while IFS= read -r line; do echo "    $line"; done
  else
    info "No logrotate activity detected."
  fi

  # Cron: match cron jobs that reference this service, or cron running systemctl
  CRON=$(journalctl --since "$CRON_START" --until "$WINDOW_END" --no-pager -o short-iso 2>/dev/null \
    | grep -i "CRON.*$SERVICE\|$SERVICE.*CRON\|cron.*systemctl.*$SERVICE" \
    || true)
  if [[ -n "$CRON" ]]; then
    found "Cron activity referencing $SERVICE detected:"
    echo "$CRON" | head -5 | while IFS= read -r line; do echo "    $line"; done
  else
    info "No cron activity referencing $SERVICE detected."
  fi
fi

# ── 7. Check for OOM killer ───────────────────────────────────────────────────
section "Checking for OOM killer"

if [[ -n "$STOP_EPOCH" ]]; then
  OOM=$(journalctl --since "$WINDOW_START" --until "$WINDOW_END" --no-pager -o short-iso 2>/dev/null \
    | grep -i "oom\|out of memory\|killed process" || true)
  if [[ -n "$OOM" ]]; then
    found "OOM killer activity detected:"
    echo "$OOM" | head -5 | while IFS= read -r line; do echo "    $line"; done
  else
    info "No OOM killer activity detected."
  fi
fi

# ── 8. Check service exit code / signal ───────────────────────────────────────
section "Checking service exit status"

EXIT_SINCE=$(date -d "@$((STOP_EPOCH - 5))"  '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((STOP_EPOCH - 5))"  '+%Y-%m-%d %H:%M:%S')
EXIT_UNTIL=$(date -d "@$((STOP_EPOCH + 30))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$((STOP_EPOCH + 30))" '+%Y-%m-%d %H:%M:%S')

EXIT_INFO=$(journalctl -u "${SERVICE}.service" --since "$EXIT_SINCE" --until "$EXIT_UNTIL" \
  --no-pager -o short-iso 2>/dev/null \
  | grep -E "exit-code|signal|status=|Main process exited|Failed with result" | tail -5 || true)
if [[ -n "$EXIT_INFO" ]]; then
  found "Exit/signal information:"
  echo "$EXIT_INFO" | while IFS= read -r line; do echo "    $line"; done
else
  info "No abnormal exit code or signal recorded at this stop event."
fi

# ── 9. Check if service has Restart= policy ───────────────────────────────────
section "Service restart policy"

RESTART_POLICY=$(systemctl show "${SERVICE}.service" --property=Restart 2>/dev/null || true)
RESTART_SEC=$(systemctl show "${SERVICE}.service" --property=RestartSec 2>/dev/null || true)
if [[ -n "$RESTART_POLICY" ]]; then
  info "$RESTART_POLICY  ($RESTART_SEC)"
  if ! echo "$RESTART_POLICY" | grep -qE "=no$|=$"; then
    warn "Service has a Restart policy — it may self-restart on failure independently of the above."
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Summary"
echo -e "  Service  : ${BOLD}$SERVICE${RESET}"
echo -e "  Analysed : ${BOLD}$STOP_TS${RESET}"
echo ""
echo -e "  ${CYAN}Check sections above for ► findings.${RESET}"
echo -e "  Cause priority:"
echo -e "    1. daemon-reexec  → shared library upgraded, systemd restarted itself"
echo -e "    2. needrestart    → library upgraded, needrestart restarted the service"
echo -e "    3. apt/dpkg       → package postinst hook restarted the service"
echo -e "    4. certbot        → certificate renewal stopped service to bind port 80"
echo -e "    5. logrotate/cron → postrotate script or scheduled job restarted service"
echo -e "    6. OOM killer     → service consumed too much memory"
echo -e "    7. manual         → human ran systemctl restart/stop"
echo -e "    8. self-restart   → service crashed, Restart= policy brought it back"
echo ""
