#!/usr/bin/env bash
# DNS / email-auth health check for a domain sending through AWS SES.
# Usage: ./check-dns.sh DOMAIN [DKIM_TOKEN ...]
#   e.g. ./check-dns.sh energyx.co.nz qwpmdgmvut66e7u5lucrrlwh6v2jiyq3 y4d3pa6vnqqun6h5oz5gliiuwe6y6uoh s5kvx5nfijwtchsrq6dn3uvx6dukef7z
#        AWS_REGION=ap-southeast-2 ./check-dns.sh energyx.co.nz ...   (also query SES status)
# Tokens may also be given as full names (TOKEN._domainkey.DOMAIN); the suffix is stripped.

set -u

usage() { echo "Usage: $0 DOMAIN [DKIM_TOKEN ...]" >&2; exit 2; }
[ $# -ge 1 ] || usage
[ -n "$1" ] || usage

# ---------- config ----------
DOMAIN="${1%.}"; shift
CNAMES=""
for arg in "$@"; do CNAMES="$CNAMES ${arg%%._domainkey*}"; done
PUBLIC_RESOLVER="8.8.8.8"
MAIL_FROM=""            # custom MAIL FROM subdomain if used, e.g. "mail.$DOMAIN"; leave empty to skip
SES_REGION="${AWS_REGION:-}"   # empty = skip the SES API check
# ----------------------------

hdr() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
inf() { printf '  ..   %s\n' "$1"; }

# Authoritative nameserver (bypasses all caches)
AUTH_NS=$(dig +short NS "$DOMAIN" @"$PUBLIC_RESOLVER" | head -1)
[ -z "$AUTH_NS" ] && { bad "No NS records found for $DOMAIN"; exit 1; }

hdr "Delegation (what the .nz registry says vs what the zone says)"
PARENT="${DOMAIN#*.}"                       # co.nz
PARENT_NS=$(dig +short NS "$PARENT" | head -1)
inf "Registry ($PARENT_NS):"
dig +norec +noall +authority NS "$DOMAIN" @"$PARENT_NS" | awk '{print "       "$NF}' | sort
inf "Zone itself ($AUTH_NS):"
dig +short NS "$DOMAIN" @"$AUTH_NS" | sed 's/^/       /' | sort

hdr "Common records (apex + www)"
for type in A AAAA MX NS TXT SOA CAA; do
  echo "--- $type"
  dig +noall +answer "$DOMAIN" "$type" @"$AUTH_NS"
done
echo "--- www"
dig +noall +answer "www.$DOMAIN" @"$AUTH_NS"

hdr "SPF"
SPF=$(dig +short TXT "$DOMAIN" @"$AUTH_NS" | grep -i 'v=spf1')
SPF_COUNT=$(printf '%s' "$SPF" | grep -c 'v=spf1')
if   [ "$SPF_COUNT" -eq 0 ]; then bad "No SPF record"
elif [ "$SPF_COUNT" -gt 1 ]; then bad "$SPF_COUNT SPF records (must be exactly one)"; echo "$SPF"
else ok "$SPF"
     echo "$SPF" | grep -q 'amazonses.com' && ok "includes amazonses.com" \
       || inf "no include:amazonses.com (fine if a custom MAIL FROM domain is used)"
fi

hdr "DMARC"
DMARC=$(dig +short TXT "_dmarc.$DOMAIN" @"$AUTH_NS")
[ -n "$DMARC" ] && ok "$DMARC" || bad "No DMARC record"

hdr "SES DKIM CNAMEs (authoritative vs public resolver)"
[ -z "${CNAMES// /}" ] && inf "Skipped: no DKIM tokens given"
for t in $CNAMES; do
  want="${t}.dkim.amazonses.com."
  a=$(dig +short CNAME "${t}._domainkey.$DOMAIN" @"$AUTH_NS")
  p=$(dig +short CNAME "${t}._domainkey.$DOMAIN" @"$PUBLIC_RESOLVER")
  dup=$(dig +short CNAME "${t}._domainkey.$DOMAIN.$DOMAIN" @"$AUTH_NS")
  if [ "$a" = "$want" ] && [ "$p" = "$want" ]; then ok "$t"
  else bad "$t  auth='${a:-none}' public='${p:-none}' expected='$want'"; fi
  [ -n "$dup" ] && bad "$t also exists as ...$DOMAIN.$DOMAIN (domain pasted twice)"
done

if [ -n "$MAIL_FROM" ]; then
  hdr "Custom MAIL FROM ($MAIL_FROM)"
  dig +noall +answer MX  "$MAIL_FROM" @"$AUTH_NS"
  dig +noall +answer TXT "$MAIL_FROM" @"$AUTH_NS"
fi

hdr "Optional email hardening"
for n in _mta-sts _smtp._tls default._bimi; do
  r=$(dig +short TXT "$n.$DOMAIN" @"$AUTH_NS")
  [ -n "$r" ] && ok "$n: $r" || inf "$n: not set"
done

hdr "DNSSEC"
DS=$(dig +short DS "$DOMAIN" @"$PUBLIC_RESOLVER")
[ -n "$DS" ] && ok "DS at registry: $DS" || inf "Not signed (no DS record)"

if [ -n "$SES_REGION" ]; then
  hdr "SES identity status ($SES_REGION)"
  if command -v aws >/dev/null; then
    aws sesv2 get-email-identity --email-identity "$DOMAIN" --region "$SES_REGION" \
      --query '{Verified:VerifiedForSendingStatus,DkimStatus:DkimAttributes.Status,Tokens:DkimAttributes.Tokens,MailFrom:MailFromAttributes}' \
      --output json
  else
    bad "aws CLI not installed"
  fi
else
  hdr "SES identity status"
  inf "Skipped: set AWS_REGION to the region you send from"
fi

hdr "Subdomains seen in certificate transparency logs (crt.sh)"
if command -v jq >/dev/null; then
  curl -s --max-time 30 "https://crt.sh/?q=%25.$DOMAIN&output=json" \
    | jq -r '.[].name_value' 2>/dev/null | sed 's/\*\.//g' | sort -u \
    || inf "crt.sh unavailable (it often times out; re-run later)"
else
  inf "jq not installed"
fi
