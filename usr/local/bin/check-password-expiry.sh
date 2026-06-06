#!/bin/bash
# Check password expiry for the sudo user and exit 1 within alert thresholds.
# Called by Monit — exit 0 = OK, exit 1 = alert.
MONITORED_USER="%%USER_SUDO_USER_USERNAME%%"
ALERT_DAYS=(30 20 10 5)

DAYS_REMAINING=$(chage -l "$MONITORED_USER" 2>/dev/null | awk -F': ' '/Password expires/ {print $2}')

# If password never expires or account not found, exit cleanly
if [[ -z "$DAYS_REMAINING" || "$DAYS_REMAINING" == "never" || "$DAYS_REMAINING" == "password must be changed" ]]; then
    exit 0
fi

# Calculate days remaining from the expiry date
EXPIRY_EPOCH=$(date -d "$DAYS_REMAINING" +%s 2>/dev/null) || exit 0
TODAY_EPOCH=$(date +%s)
DAYS_LEFT=$(( (EXPIRY_EPOCH - TODAY_EPOCH) / 86400 ))

for THRESHOLD in "${ALERT_DAYS[@]}"; do
    if [[ "$DAYS_LEFT" -le "$THRESHOLD" ]]; then
        echo "Password for $MONITORED_USER expires in $DAYS_LEFT day(s) (on $DAYS_REMAINING)."
        exit 1
    fi
done

exit 0
