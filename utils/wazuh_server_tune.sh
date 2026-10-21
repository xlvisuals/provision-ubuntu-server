#!/usr/bin/env bash
# wazuh_server_tune.sh — tune an all-in-one Wazuh server (indexer + manager + filebeat + dashboard)
#
# Called by ubuntu_provision.sh after the Wazuh server install, and safe to run by hand
# on an existing server. Every action is opt-in through an environment variable; a
# variable that is unset or empty means "leave that setting alone". Nothing is guessed.
#
#   WAZUH_INDEXER_HEAP_MB          'auto' (half of RAM, 1024..31744 MB) or a number of MB (512..31744).
#                                  Edits /etc/wazuh-indexer/jvm.options and restarts the indexer if it changed.
#   WAZUH_ALERTS_SHARDS            primary shards per NEW wazuh-alerts index (1..10). Edits
#                                  /etc/filebeat/wazuh-template.json and restarts filebeat.
#                                  Existing indices keep their shard count.
#   WAZUH_ALERTS_RETENTION_DAYS    create an ISM policy that deletes wazuh-alerts-* indices after N days
#                                  (7..3650). 0 or empty = no policy. Applies to NEW indices only unless:
#   WAZUH_RETENTION_APPLY_EXISTING y = also attach the policy to EXISTING indices. Indices older than N days
#                                  are then DELETED within minutes. Unset = ask (terminal only), otherwise no.
#   WAZUH_CREATE_HEALTH_USER       y = create a read-only indexer user 'wazuh_health' and write
#                                  /etc/wazuh-health.conf (root:root 600) for ubuntu_health_check.sh.
#   WAZUH_ADMIN_USER               indexer admin user for the API calls (default: admin)
#   WAZUH_ADMIN_PASSWORD           indexer admin password. Unset = prompted on a terminal (Enter skips the
#                                  steps that need it). It is never defaulted and never put on a command line.
#
# Example (existing server, 90 day retention, 1 shard, 4 GB heap, health user):
#   sudo WAZUH_INDEXER_HEAP_MB=4096 WAZUH_ALERTS_SHARDS=1 WAZUH_ALERTS_RETENTION_DAYS=90 \
#        WAZUH_CREATE_HEALTH_USER=y ./utils/wazuh_server_tune.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[!] This script must be run as root (sudo)." >&2
    exit 1
fi

JVM_OPTIONS=/etc/wazuh-indexer/jvm.options
FILEBEAT_TEMPLATE=/etc/filebeat/wazuh-template.json
HEALTH_CONF=/etc/wazuh-health.conf
HEALTH_USER=wazuh_health
ISM_POLICY_ID=wazuh-alerts-retention
INDEXER_URL=https://127.0.0.1:9200   # loopback only; self-signed cert, so -k is used for curl below

ok()   { echo "  [V] $*"; }
note() { echo "  [=] $*"; }
warn() { echo "  [!] $*" >&2; }

if [[ -z "${WAZUH_INDEXER_HEAP_MB:-}${WAZUH_ALERTS_SHARDS:-}${WAZUH_ALERTS_RETENTION_DAYS:-}${WAZUH_CREATE_HEALTH_USER:-}" ]]; then
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
fi

if ! systemctl list-unit-files wazuh-indexer.service 2>/dev/null | grep -q wazuh-indexer.service; then
    warn "wazuh-indexer is not installed on this host."
    exit 1
fi

HEAP_CHANGED=n
TEMPLATE_CHANGED=n

# ---------------------------------------------------------------------------
# 1. Indexer heap (no credentials needed)
# ---------------------------------------------------------------------------
heap_to_mb() {   # "4g" -> 4096, "2048m" -> 2048
    local v="$1"
    case "${v: -1}" in
        g|G) echo $(( ${v%?} * 1024 )) ;;
        *)   echo "${v%?}" ;;
    esac
}

if [[ -n "${WAZUH_INDEXER_HEAP_MB:-}" ]]; then
    echo "--- Indexer heap ---"
    RAM_MB=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    TARGET_MB=""
    if [[ "$WAZUH_INDEXER_HEAP_MB" == "auto" ]]; then
        TARGET_MB=$(( ( RAM_MB / 2 + 256 ) / 512 * 512 ))   # half of RAM, rounded to the nearest 512 MB
        (( TARGET_MB > 31744 )) && TARGET_MB=31744
        (( TARGET_MB < 1024 ))  && TARGET_MB=1024
    elif [[ "$WAZUH_INDEXER_HEAP_MB" =~ ^[0-9]+$ ]] && (( WAZUH_INDEXER_HEAP_MB >= 512 && WAZUH_INDEXER_HEAP_MB <= 31744 )); then
        TARGET_MB="$WAZUH_INDEXER_HEAP_MB"
    else
        warn "WAZUH_INDEXER_HEAP_MB='$WAZUH_INDEXER_HEAP_MB' is not 'auto' or a number between 512 and 31744 — heap left unchanged."
    fi

    if [[ -n "$TARGET_MB" ]]; then
        if (( TARGET_MB * 100 > RAM_MB * 60 )); then
            warn "Heap ${TARGET_MB} MB is more than 60% of the ${RAM_MB} MB RAM — refusing, heap left unchanged."
        elif [[ ! -f "$JVM_OPTIONS" ]]; then
            warn "$JVM_OPTIONS not found — heap left unchanged."
        else
            CUR_XMS=$(sed -n 's/^-Xms\([0-9]\+[mMgG]\)$/\1/p' "$JVM_OPTIONS" | head -1)
            CUR_XMX=$(sed -n 's/^-Xmx\([0-9]\+[mMgG]\)$/\1/p' "$JVM_OPTIONS" | head -1)
            if [[ -z "$CUR_XMS" || -z "$CUR_XMX" ]]; then
                warn "Could not find both -Xms and -Xmx lines in $JVM_OPTIONS — heap left unchanged."
            elif [[ "$(heap_to_mb "$CUR_XMS")" == "$TARGET_MB" && "$(heap_to_mb "$CUR_XMX")" == "$TARGET_MB" ]]; then
                note "Heap already ${TARGET_MB} MB."
            else
                BACKUP="$JVM_OPTIONS.bak-$(date +%F_%H%M%S)"
                cp -p "$JVM_OPTIONS" "$BACKUP"
                sed -i -E "s/^-Xms[0-9]+[mMgG]$/-Xms${TARGET_MB}m/; s/^-Xmx[0-9]+[mMgG]$/-Xmx${TARGET_MB}m/" "$JVM_OPTIONS"
                if [[ "$(grep -cE "^-Xm[sx]${TARGET_MB}m$" "$JVM_OPTIONS")" == "2" ]]; then
                    ok "Heap ${CUR_XMX} -> ${TARGET_MB}m (backup: $BACKUP)"
                    HEAP_CHANGED=y
                else
                    cp -p "$BACKUP" "$JVM_OPTIONS"
                    warn "Heap edit did not verify — restored $JVM_OPTIONS from backup."
                fi
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 2. Shards for new daily alert indices (filebeat template; no credentials needed)
# ---------------------------------------------------------------------------
if [[ -n "${WAZUH_ALERTS_SHARDS:-}" ]]; then
    echo "--- Shards for new wazuh-alerts indices ---"
    if ! [[ "$WAZUH_ALERTS_SHARDS" =~ ^[0-9]+$ ]] || (( WAZUH_ALERTS_SHARDS < 1 || WAZUH_ALERTS_SHARDS > 10 )); then
        warn "WAZUH_ALERTS_SHARDS='$WAZUH_ALERTS_SHARDS' is not a number between 1 and 10 — template left unchanged."
    elif [[ ! -f "$FILEBEAT_TEMPLATE" ]]; then
        warn "$FILEBEAT_TEMPLATE not found — template left unchanged."
    elif ! grep -qE '"index\.number_of_shards"[[:space:]]*:' "$FILEBEAT_TEMPLATE"; then
        warn "No \"index.number_of_shards\" key in $FILEBEAT_TEMPLATE — template left unchanged."
    elif grep -qE "\"index\.number_of_shards\"[[:space:]]*:[[:space:]]*\"?${WAZUH_ALERTS_SHARDS}\"?[[:space:]]*,?[[:space:]]*$" "$FILEBEAT_TEMPLATE"; then
        note "Template already sets ${WAZUH_ALERTS_SHARDS} shard(s)."
    else
        BACKUP="$FILEBEAT_TEMPLATE.bak-$(date +%F_%H%M%S)"
        cp -p "$FILEBEAT_TEMPLATE" "$BACKUP"
        sed -i -E "s/(\"index\.number_of_shards\"[[:space:]]*:[[:space:]]*)\"?[0-9]+\"?/\1\"${WAZUH_ALERTS_SHARDS}\"/" "$FILEBEAT_TEMPLATE"
        if grep -qE "\"index\.number_of_shards\"[[:space:]]*:[[:space:]]*\"${WAZUH_ALERTS_SHARDS}\"" "$FILEBEAT_TEMPLATE"; then
            ok "Template now sets ${WAZUH_ALERTS_SHARDS} shard(s) (backup: $BACKUP)"
            TEMPLATE_CHANGED=y
        else
            cp -p "$BACKUP" "$FILEBEAT_TEMPLATE"
            warn "Template edit did not verify — restored $FILEBEAT_TEMPLATE from backup."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Restart what changed, then wait for the indexer to answer
# ---------------------------------------------------------------------------
wait_for_indexer() {   # any HTTP answer (200/401/503) means the port is up
    local i code
    for (( i = 0; i < 60; i++ )); do
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$INDEXER_URL" 2>/dev/null || true)
        [[ -n "$code" && "$code" != "000" ]] && return 0
        sleep 3
    done
    return 1
}

if [[ "$HEAP_CHANGED" == "y" ]]; then
    echo "--- Restarting wazuh-indexer (shard recovery can take several minutes; cluster is red meanwhile) ---"
    systemctl restart wazuh-indexer
    wait_for_indexer && ok "Indexer is answering again." || warn "Indexer did not answer within 3 minutes — check: journalctl -u wazuh-indexer"
fi
if [[ "$TEMPLATE_CHANGED" == "y" ]]; then
    echo "--- Restarting filebeat to load the template ---"
    systemctl restart filebeat && ok "filebeat restarted" || warn "filebeat restart failed"
fi

# ---------------------------------------------------------------------------
# Steps that need the indexer admin credentials
# ---------------------------------------------------------------------------
RET_DAYS=""
if [[ -n "${WAZUH_ALERTS_RETENTION_DAYS:-}" && "${WAZUH_ALERTS_RETENTION_DAYS}" != "0" ]]; then
    if [[ "$WAZUH_ALERTS_RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( WAZUH_ALERTS_RETENTION_DAYS >= 7 && WAZUH_ALERTS_RETENTION_DAYS <= 3650 )); then
        RET_DAYS="$WAZUH_ALERTS_RETENTION_DAYS"
    else
        warn "WAZUH_ALERTS_RETENTION_DAYS='$WAZUH_ALERTS_RETENTION_DAYS' is not between 7 and 3650 — no retention policy created."
    fi
fi
WANT_HEALTH_USER=n
[[ "${WAZUH_CREATE_HEALTH_USER:-}" =~ ^[Yy]$ ]] && WANT_HEALTH_USER=y

NEED_AUTH=n
[[ -n "$RET_DAYS" || "$WANT_HEALTH_USER" == "y" || "$TEMPLATE_CHANGED" == "y" ]] && NEED_AUTH=y
[[ "$NEED_AUTH" == "y" ]] || { echo "Done."; exit 0; }

echo "--- Indexer API steps ---"
if ! command -v jq >/dev/null 2>&1; then
    apt-get install -y -o Dpkg::Use-Pty=0 jq >/dev/null 2>&1 || true
fi
if ! command -v jq >/dev/null 2>&1; then
    warn "jq is required for the API steps and could not be installed — skipping them."
    exit 0
fi

ADMIN_USER="${WAZUH_ADMIN_USER:-admin}"
ADMIN_PASS="${WAZUH_ADMIN_PASSWORD:-}"
if [[ -z "$ADMIN_PASS" && -t 0 ]]; then
    read -rsp "  Wazuh indexer password for '$ADMIN_USER' (Enter to skip these steps): " ADMIN_PASS; echo ""
fi
if [[ -z "$ADMIN_PASS" ]]; then
    warn "No admin password available — skipping retention policy, health user and template check."
    exit 0
fi

CURL_CFG=$(mktemp)
IDX_TMP=$(mktemp)
trap 'rm -f "$CURL_CFG" "$IDX_TMP"; ADMIN_PASS=""; WAZUH_ADMIN_PASSWORD=""' EXIT
chmod 600 "$CURL_CFG" "$IDX_TMP"

IDX_CODE=000
IDX_BODY=""
idx_call() {   # idx_call USER PASS METHOD PATH [JSON] -> sets IDX_CODE, IDX_BODY. Credentials go via a 600 curl config, JSON via stdin.
    local user="$1" pass="$2" method="$3" path="$4" json="${5:-}" cred
    cred="${user}:${pass}"; cred=${cred//\\/\\\\}; cred=${cred//\"/\\\"}
    printf 'user = "%s"\n' "$cred" > "$CURL_CFG"
    if [[ -n "$json" ]]; then
        IDX_CODE=$(printf '%s' "$json" | curl -sk --max-time 90 -K "$CURL_CFG" -X "$method" \
            -H 'Content-Type: application/json' --data-binary @- -o "$IDX_TMP" -w '%{http_code}' "${INDEXER_URL}${path}") || IDX_CODE=000
    else
        IDX_CODE=$(curl -sk --max-time 90 -K "$CURL_CFG" -X "$method" \
            -H 'Content-Type: application/json' -o "$IDX_TMP" -w '%{http_code}' "${INDEXER_URL}${path}") || IDX_CODE=000
    fi
    IDX_BODY=$(cat "$IDX_TMP")
}
admin_call() { idx_call "$ADMIN_USER" "$ADMIN_PASS" "$@"; }

admin_call GET "/"
if [[ "$IDX_CODE" != "200" ]]; then
    warn "Indexer login as '$ADMIN_USER' failed (HTTP $IDX_CODE) — skipping the API steps. Nothing was tried with any other credentials."
    exit 2
fi
ok "Logged in to the indexer as '$ADMIN_USER'."

admin_call GET "/_cluster/health?wait_for_status=yellow&timeout=120s"
CL_STATUS=$(jq -r '.status // "unknown"' <<<"$IDX_BODY" 2>/dev/null || echo unknown)
[[ "$CL_STATUS" == "green" || "$CL_STATUS" == "yellow" ]] || warn "Cluster status is '$CL_STATUS' — continuing, but some calls may fail until shards are recovered."

# ---- template check ----
if [[ "$TEMPLATE_CHANGED" == "y" ]]; then
    admin_call GET "/_template/wazuh?filter_path=wazuh.settings.index.number_of_shards"
    LIVE_SHARDS=$(jq -r '.wazuh.settings.index.number_of_shards // empty' <<<"$IDX_BODY" 2>/dev/null || true)
    if [[ "$LIVE_SHARDS" == "$WAZUH_ALERTS_SHARDS" ]]; then
        ok "Indexer template 'wazuh' now has ${LIVE_SHARDS} shard(s) — applies from the next daily index."
    else
        warn "Indexer template 'wazuh' reports '${LIVE_SHARDS:-unknown}' shard(s), expected ${WAZUH_ALERTS_SHARDS}."
        warn "If filebeat.yml lacks 'setup.template.overwrite: true', load it with:  sudo filebeat setup --index-management"
    fi
fi

# ---- retention policy ----
if [[ -n "$RET_DAYS" ]]; then
    echo "--- Retention policy: delete wazuh-alerts-* after ${RET_DAYS} days ---"
    POLICY_JSON=$(jq -n --arg age "${RET_DAYS}d" '{policy: {
        description: "Delete wazuh-alerts indices after a fixed age",
        default_state: "hot",
        states: [
          {name: "hot",    actions: [], transitions: [{state_name: "delete", conditions: {min_index_age: $age}}]},
          {name: "delete", actions: [{delete: {}}], transitions: []}
        ],
        ism_template: [{index_patterns: ["wazuh-alerts-*"], priority: 100}]
    }}')
    admin_call GET "/_plugins/_ism/policies/${ISM_POLICY_ID}"
    if [[ "$IDX_CODE" == "200" ]]; then
        CUR_AGE=$(jq -r '.policy.states[]? | select(.name=="hot") | .transitions[0].conditions.min_index_age // empty' <<<"$IDX_BODY")
        SEQ=$(jq -r '._seq_no' <<<"$IDX_BODY"); PRI=$(jq -r '._primary_term' <<<"$IDX_BODY")
        if [[ "$CUR_AGE" == "${RET_DAYS}d" ]]; then
            note "Policy '${ISM_POLICY_ID}' already exists with ${RET_DAYS}d."
        else
            admin_call PUT "/_plugins/_ism/policies/${ISM_POLICY_ID}?if_seq_no=${SEQ}&if_primary_term=${PRI}" "$POLICY_JSON"
            [[ "$IDX_CODE" == "200" || "$IDX_CODE" == "201" ]] && ok "Policy '${ISM_POLICY_ID}' updated (${CUR_AGE:-?} -> ${RET_DAYS}d). Already-managed indices keep the old version until re-attached." \
                                       || warn "Updating policy failed (HTTP $IDX_CODE): $(jq -r '.error.reason // .' <<<"$IDX_BODY" 2>/dev/null | head -c 300)"
        fi
    elif [[ "$IDX_CODE" == "404" ]]; then
        admin_call PUT "/_plugins/_ism/policies/${ISM_POLICY_ID}" "$POLICY_JSON"
        [[ "$IDX_CODE" == "200" || "$IDX_CODE" == "201" ]] && ok "Policy '${ISM_POLICY_ID}' created; it attaches to NEW wazuh-alerts-* indices." \
                                                          || warn "Creating policy failed (HTTP $IDX_CODE): $(jq -r '.error.reason // .' <<<"$IDX_BODY" 2>/dev/null | head -c 300)"
    else
        warn "Could not read ISM policies (HTTP $IDX_CODE) — retention policy not created."
    fi

    # existing indices: destructive, so explicit
    admin_call GET "/_cat/indices/wazuh-alerts-*?h=index,creation.date&format=json"
    if [[ "$IDX_CODE" == "200" ]]; then
        CUTOFF_MS=$(( ( $(date +%s) - RET_DAYS * 86400 ) * 1000 ))
        N_ALL=$(jq 'length' <<<"$IDX_BODY")
        N_OLD=$(jq --argjson c "$CUTOFF_MS" '[.[] | select((."creation.date" | tonumber) < $c)] | length' <<<"$IDX_BODY")
        echo "  Existing wazuh-alerts indices: ${N_ALL}, of which ${N_OLD} older than ${RET_DAYS} days."
        APPLY="${WAZUH_RETENTION_APPLY_EXISTING:-}"
        if [[ -z "$APPLY" && -t 0 && "$N_ALL" != "0" ]]; then
            read -rp "  Attach the policy to the ${N_ALL} existing indices now? ${N_OLD} would be DELETED within minutes. (y/n) " APPLY
        fi
        if [[ "$APPLY" =~ ^[Yy]$ && "$N_ALL" != "0" ]]; then
            admin_call POST "/_plugins/_ism/add/wazuh-alerts-*" "$(jq -n --arg p "$ISM_POLICY_ID" '{policy_id: $p}')"
            if [[ "$IDX_CODE" == "200" ]]; then
                ok "Policy attached to $(jq -r '.updated_indices' <<<"$IDX_BODY") existing index(es); failed/skipped: $(jq -r '.failed_indices | length' <<<"$IDX_BODY")."
            else
                warn "Attaching the policy failed (HTTP $IDX_CODE)."
            fi
        else
            note "Existing indices left untouched (not attached to the policy)."
        fi
    fi
fi

# ---- read-only health user ----
if [[ "$WANT_HEALTH_USER" == "y" ]]; then
    echo "--- Read-only health user '${HEALTH_USER}' ---"
    EXISTING_USER=""; EXISTING_PASS=""
    if [[ -f "$HEALTH_CONF" && "$(stat -c '%U:%G %a' "$HEALTH_CONF")" == "root:root 600" ]]; then
        EXISTING_USER=$(sed -n 's/^WAZUH_HEALTH_USER=//p' "$HEALTH_CONF" | head -1)
        EXISTING_PASS=$(sed -n 's/^WAZUH_HEALTH_PASSWORD=//p' "$HEALTH_CONF" | head -1)
    fi
    if [[ "$EXISTING_USER" == "$HEALTH_USER" && -n "$EXISTING_PASS" ]]; then
        idx_call "$EXISTING_USER" "$EXISTING_PASS" GET "/_cluster/health?filter_path=status"
    else
        IDX_CODE=000
    fi
    if [[ "$IDX_CODE" == "200" ]]; then
        note "$HEALTH_CONF already holds working credentials."
    else
        NEW_PASS=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32 || true)
        if [[ ${#NEW_PASS} -ne 32 ]]; then
            warn "Could not generate a password — health user not created."
        else
            ROLE_JSON=$(jq -n '{cluster_permissions: ["cluster_monitor"], index_permissions: [{index_patterns: ["*"], allowed_actions: ["indices_monitor"]}]}')
            USER_JSON=$(jq -n --arg p "$NEW_PASS" '{password: $p, backend_roles: [], attributes: {purpose: "read-only health check"}}')
            MAP_JSON=$(jq -n --arg u "$HEALTH_USER" '{users: [$u]}')
            FAILED=n
            admin_call PUT "/_plugins/_security/api/roles/${HEALTH_USER}" "$ROLE_JSON"
            [[ "$IDX_CODE" == "200" || "$IDX_CODE" == "201" ]] || { warn "Creating role failed (HTTP $IDX_CODE): $(jq -r '.message // .' <<<"$IDX_BODY" 2>/dev/null | head -c 300)"; FAILED=y; }
            if [[ "$FAILED" == "n" ]]; then
                admin_call PUT "/_plugins/_security/api/internalusers/${HEALTH_USER}" "$USER_JSON"
                [[ "$IDX_CODE" == "200" || "$IDX_CODE" == "201" ]] || { warn "Creating user failed (HTTP $IDX_CODE): $(jq -r '.message // .' <<<"$IDX_BODY" 2>/dev/null | head -c 300)"; FAILED=y; }
            fi
            if [[ "$FAILED" == "n" ]]; then
                admin_call PUT "/_plugins/_security/api/rolesmapping/${HEALTH_USER}" "$MAP_JSON"
                [[ "$IDX_CODE" == "200" || "$IDX_CODE" == "201" ]] || { warn "Mapping role failed (HTTP $IDX_CODE): $(jq -r '.message // .' <<<"$IDX_BODY" 2>/dev/null | head -c 300)"; FAILED=y; }
            fi
            if [[ "$FAILED" == "n" ]]; then
                idx_call "$HEALTH_USER" "$NEW_PASS" GET "/_cluster/health?filter_path=status"
                if [[ "$IDX_CODE" == "200" ]]; then
                    ( umask 077
                      {
                        echo "# Read-only Wazuh indexer user for ubuntu_health_check.sh. Written by wazuh_server_tune.sh."
                        echo "WAZUH_HEALTH_USER=${HEALTH_USER}"
                        echo "WAZUH_HEALTH_PASSWORD=${NEW_PASS}"
                        echo "WAZUH_ALERTS_RETENTION_DAYS=${RET_DAYS}"
                      } > "${HEALTH_CONF}.new" )
                    chown root:root "${HEALTH_CONF}.new"; chmod 600 "${HEALTH_CONF}.new"
                    mv -f "${HEALTH_CONF}.new" "$HEALTH_CONF"
                    ok "User '${HEALTH_USER}' created and verified; credentials in $HEALTH_CONF (root only)."
                else
                    warn "Health user was created but its login test failed (HTTP $IDX_CODE) — $HEALTH_CONF not written."
                fi
            fi
        fi
        NEW_PASS=""
    fi
fi

# keep the retention value the health check compares against in step with the policy
if [[ -n "$RET_DAYS" && -f "$HEALTH_CONF" && "$(stat -c '%U:%G %a' "$HEALTH_CONF")" == "root:root 600" ]]; then
    sed -i '/^WAZUH_ALERTS_RETENTION_DAYS=/d' "$HEALTH_CONF"
    echo "WAZUH_ALERTS_RETENTION_DAYS=${RET_DAYS}" >> "$HEALTH_CONF"
fi

echo "Done."
