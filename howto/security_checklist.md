# Security Checklist — Full Stack (App, Infra, Dev/Staging, Process)

## Application layer (OWASP-type issues)
- [ ] OWASP ZAP scan run and issues fixed
- [ ] SQL injection review of raw `text()`/string-built queries (manual grep, not just ZAP)
- [ ] Mass assignment review (`Model(**request.json)` patterns)
- [ ] IDOR — automated script testing cross-user and guest access, all permutations
- [ ] JWT/session `SECRET_KEY` entropy check (not default, not in git)
- [ ] Session cookie flags: `SameSite=Strict`
- [ ] CSRF protection enabled and applied across all blueprints
- [ ] Deserialization review (`pickle` usage anywhere, incl. session backends)
- [ ] File upload handling (path traversal, content-type validation, execution risk)
- [ ] SSRF — N/A, app doesn't fetch 3rd-party data on user's behalf
- [ ] SSTI — N/A, no Jinja templates rendering user input (Vue frontend, server-side auth)
- [ ] Race conditions / TOCTOU on business logic (coupons, balances, one-time actions) — tooling provided, review pending
- [ ] Negative/overflow value handling on quantities, amounts, prices
- [ ] Workflow step-skipping (multi-step processes callable out of order)
- [ ] Replay of expired/used tokens or requests
- [ ] Timing attack / user enumeration on login, signup, password reset
- [ ] Rate limiting on login and password reset
- [ ] Session/token invalidation completeness (password change, logout revocation) — in progress
- [ ] Linear read-through of auth decorators/middleware for missing `@login_required`/role checks
- [ ] Role/permission checks compare against authoritative DB value, not stale session/JWT claim

## Dependencies / supply chain
- [ ] `vet` and `trivy` scans for supply chain vulnerabilities
- [ ] `gitleaks` / `trufflehog` run against full git history (not just HEAD) — planned

## Secrets management
- [ ] MySQL password removed from git, moved to `.env` — rotation should happen first, before history rewrite
- [ ] Confirm no other secrets in git history once scanned

## Frontend (Vue.js)
- [ ] Source maps not deployed to production
- [ ] Backend never trusts frontend for auth/authz decisions

## Database
- [ ] Separate DB users: minimal-privilege app runtime user vs. elevated backup/maintenance user — identified, not yet split
- [ ] Confirm `secure_file_priv` set on MySQL (blocks `LOAD_FILE`/`INTO OUTFILE` regardless of grants)
- [ ] Confirm app runtime user has no `FILE` privilege, no access to `mysql.*` system tables

## Infrastructure hardening (per-client production VPS)
- [ ] UFW firewall
- [ ] Fail2Ban
- [ ] Suricata (network IDS)
- [ ] auditd
- [ ] Wazuh agent
- [ ] IP blocklists
- [ ] Daily security updates
- [ ] Weekly feature/kernel updates
- [ ] Weekly log reviews
- [ ] SSH: key-only auth, no passwords, IP-locked
- [ ] Isolated per-client VPS architecture (no shared DB/network across clients)
- [ ] HTTP request smuggling test (nginx ↔ gunicorn TE/CL header desync)

## Admin access
- [ ] No admin panels exposed to internet
- [ ] Admin access localhost-only via SSH (IP-locked, key-only)

## CI/CD
- [ ] No exposed CI/CD pipeline — deploy is local bash scripts on staging, not internet-facing
- [ ] Deploy scripts scoped minimally (can't be reused to pivot to other clients' VPSes)
- [ ] Deploy scripts don't leak secrets into shell history/logs in plaintext

## Source control (Forgejo, self-hosted)
- [ ] Private Forgejo server, no public HTTP/other interface
- [ ] SSH-only access, key-based, IP whitelist
- [ ] SSH key(s) used for Forgejo access are passphrase-protected (same discipline as staging/prod keys)
- [ ] Forgejo server patched on same cadence as production VPS fleet
- [ ] Forgejo repo data + CI secrets covered by same offsite backup process as production

## Backups
- [ ] Backups downloaded and stored offsite
- [ ] Two independent dedicated computers, separate networks
- [ ] Backups encrypted at rest
- [ ] Backup encryption key stored separately from backup machines (3rd location / hardware token)
- [ ] Confirm backups don't contain unnecessarily exposed sensitive fields (PII, hashes) beyond what restore requires

## Dev machine
- [ ] FileVault full-disk encryption enabled
- [ ] macOS security updates on a known cadence
- [ ] Firmware password set (prevents boot-from-external-media bypass of FileVault)
- [ ] Local admin account separate from daily-use account
- [ ] Screen lock on sleep, short timeout
- [ ] 1Password account secured with hardware key (YubiKey) 2FA — highest-leverage single item
- [ ] SSH keys to staging/Forgejo are passphrase-protected, not bare on disk
- [ ] `ssh-agent` short timeout rather than keys loaded indefinitely
- [ ] No secrets in PyCharm run configs, stray `.env` files, or scratch files outside gitignore
- [ ] PyCharm plugin list reviewed, unused plugins removed
- [ ] VSCodium extension list reviewed (Open VSX source, same supply-chain risk as VS Code marketplace)
- [ ] Homebrew formulae/casks audited periodically (`brew list`, `brew doctor`)
- [ ] Confirm no AI coding assistant plugins with broad file/shell access installed unintentionally
- [ ] Python installs use per-project virtualenvs, not global `pip install`
- [ ] Thunderbird: remote content/images blocked by default
- [ ] Firefox extensions reviewed same as PyCharm/VSCodium
- [ ] Consider separate browser profile/identity for general browsing vs. work on this machine
- [ ] macOS software firewall enabled
- [ ] Local MySQL bound to `127.0.0.1`, not `0.0.0.0`
- [ ] No unnecessary listening services (`sudo lsof -i -P | grep LISTEN`)

## Staging machine (Ubuntu, per-client, mirrors production)
- [ ] Same patch/monitoring cadence as production (not lighter "because it's staging")
- [ ] Staging DB doesn't contain real/unscrubbed production data
- [ ] SSH access restricted to dev machine's specific IP (mirroring production's IP-lock)

## Dev ↔ Staging network
- [ ] Dev/staging network segment genuinely isolated (VLAN) from general office/guest wifi, not just "same building"

## Process / organizational
- [ ] 2FA on VPS/hosting provider, domain registrar, DNS provider accounts
- [ ] Manual pentest / red team engagement (recommended given maturity of current posture)

---

**Legend:** `[ ]` = confirmed covered in this conversation · `[ ]` = not yet confirmed / open item

**Suggested next priorities**, roughly in order of impact vs. effort:
1. Hardware key (YubiKey) 2FA on 1Password — single highest-leverage item, unlocks everything else
2. Rotate MySQL password (before any git history cleanup)
3. FileVault + firmware password on dev machine
4. Split DB users (app runtime vs. backup/maintenance)
5. Run race condition tests against coupon/balance/one-time-action endpoints
6. `gitleaks`/`trufflehog` against full git history
7. PyCharm/VSCodium extension audit; confirm no unintended AI-assistant plugins
8. Verify session/token invalidation on password change
9. Encrypt backups at rest
10. Confirm dev/staging network segmentation
11. Enable 2FA on hosting/registrar/DNS accounts
12. Book a manual pentest
