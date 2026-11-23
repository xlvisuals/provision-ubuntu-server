# Howto: Incident response

## Background

This is the procedure for a suspected compromise of a server set up with `ubuntu_provision.sh`:
a VPS with nginx, MySQL/MariaDB, Suricata, Forgejo, the Wazuh agent, auditd, and one or more
gunicorn web apps in `/home/xlvisuals/<domain>/` that read their secrets from
`/etc/xlvisuals/<domain_with_underscores>.env`.

It covers the phases up to the rebuild:

| Phase | Goal | Script command |
|---|---|---|
| 1. Identification | Notice that something is wrong, start the incident log | – |
| 2. Triage | Decide: false alarm or incident, and how bad | `triage` |
| 3. Containment | Stop the damage without destroying evidence | `collect` (volatile part), `contain …` |
| 4. Investigation | Entry point, earliest compromise time, what was touched | `collect`, `investigate` |
| 5. Export | Get the evidence off the server, intact | `export` |
| 6. Eradication & recovery | New VPS from backup, rotate every secret | `secrets` (checklist) |

**Eradication and recovery are always a rebuild**: the old VPS is not cleaned, it is replaced by
a new one built from a trusted copy of this repository and a backup from before the compromise.
Everything below exists to answer three questions for that rebuild:

1. **When** did it start? This decides which backup is clean.
2. **How** did they get in? If you do not fix it, the new server is compromised the same way.
3. **What** did they reach? This decides which secrets to rotate and whom to notify.

The script `ubuntu_incident_response.sh` does the typing. Everything it does except `contain` is
read-only on the server apart from writing its case directory (`/root/ir/<host>_<time>/`).

### Rules that apply throughout

- **Do not reboot, shut down, reinstall packages, run `apt upgrade`, restart services or delete
  "the bad file"** before evidence is collected. Running processes, network connections and deleted
  programs that are still running only exist in memory.
- **Take a provider snapshot first** if your provider offers one. After that, writing the case
  directory to the disk costs nothing.
- **Never use SSH agent forwarding (`ssh -A`) to a suspect server**; root there can use your agent
  to log in elsewhere as you. Public-key login itself is safe: your private key never leaves your machine.
- **Your sudo password is burned** as soon as you type it into the suspect server (a trojaned
  `sudo` or PAM module can record it). Use it there, and never use it anywhere else again.
- **Do not trust tools on the server.** Root can replace `ps`, `ss`, `ls`. The script checks the core
  packages with `dpkg --verify`, but the independent record is on the **Wazuh manager**: its alerts,
  FIM history and copies of the logs cannot be edited from the agent.
- **Run the script from your workstation's copy**, not a copy that lives on the server.
- **Write everything down** with UTC times (the server runs in UTC).

---

## 0. Prepare now (before an incident)

Ten minutes now saves hours later:

- [ ] Keep `ubuntu_incident_response.sh` on your workstation, and note its sha256.
- [ ] Have a GPG key pair for evidence (public key file ready for `--encrypt-to`):
      `gpg --quick-gen-key "IR Evidence <you@example.com>"` and
      `gpg --export -a you@example.com > ir_pub.asc`.
- [ ] Know how to reach the **provider console** (out-of-band login), **provider firewall** and
      **snapshots** for each VPS. 2FA on the provider account.
- [ ] Note the fixed IP address(es) you administer from (needed for `--admin-ip`).
- [ ] Check the Wazuh manager keeps alerts and archives long enough (90 days or more).
- [ ] Check backups: their dates, that you can restore them, and that they are offline/immutable
      (an attacker with root on the server must not be able to delete or change them).
- [ ] Run `sudo bash ubuntu_incident_response.sh secrets --new-case` on each healthy server and keep
      `secrets/rotation_checklist.md`: this is the list of what you would have to rotate. Then
      `sudo rm -rf /root/ir` (it contains no secret values, only names and paths).
- [ ] Keep a contact list: hosting provider abuse/support, customers' contacts, whoever decides on
      notifying the Privacy Commissioner, a lawyer if needed.

---

## 1. Identification

### Signals on this stack

| Source | What to look for |
|---|---|
| Wazuh dashboard (manager) | High-level alerts (rule level ≥ 10), FIM changes in `/etc`, `/usr/bin`, the app directories; new users; sudo to root at odd times; agent disconnected |
| Suricata (via Wazuh, or `eve.json`) | Alerts where **this server is the source** (outbound C2, scanning, mining pools); exploit signatures against nginx followed by unusual responses |
| Monit mails | Services restarted or stopped (especially auditd, wazuh-agent, suricata, fail2ban), high CPU or load, disk filling |
| AIDE daily mail (`/var/log/aide/aide-check.log`; only on servers without Wazuh, which does FIM instead) | Changed binaries or config without a matching apt run or deployment |
| Your own eyes | Unknown process in `btop`, CPU at 100 % (miner), unknown cron job, a file you did not create, odd entries in `last` |
| Outside the server | Provider abuse notice (the server is attacking others or sending spam); SMTP provider complaint; traffic or billing spike; customers reporting odd behaviour, phishing or account takeovers; TLS certificates you did not request on [crt.sh](https://crt.sh); DNS records changed; unexpected pushes in Forgejo |

### Start the incident log

Before touching anything, open a text file **on your workstation** (not the server):

```
Incident: <short name>            Opened: 2026-11-23 09:30 UTC by <name>
Server(s): www.xlvisuals.com (203.0.113.10), provider <...>
How noticed: <alert / mail / report, with its time>

Time (UTC)        Who   What was done / observed
2026-11-23 09:30  AB    Wazuh alert 5402 "sudo to root" for user xlvisuals at 03:12 UTC, not me
2026-11-23 09:41  AB    Provider snapshot taken: snap-1234
...
Decisions:
Evidence: <archive name>  sha256 <...>  stored at <...>
```

Every action goes in, including the ones that turned out to be wrong.

---

## 2. Triage

### Run the triage

From your workstation:

```bash
# copy the trusted script to the server and check it arrived unchanged
scp ubuntu_incident_response.sh you@203.0.113.10:
sha256sum ubuntu_incident_response.sh
ssh you@203.0.113.10                     # no -A
sha256sum ~/ubuntu_incident_response.sh  # must match the workstation's value

sudo bash ~/ubuntu_incident_response.sh triage --admin-ip 198.51.100.7
```

`--admin-ip` is the address (or CIDR, comma-separated) you administer from. With it, SSH logins
from any other address are flagged HIGH. Triage takes a minute or two and saves its raw output in
`/root/ir/<host>_<time>/triage/`.

What it checks: UID 0 accounts, empty passwords, SSH settings and every `authorized_keys`,
successful SSH logins in the window (password logins are HIGH: the provisioning disables them),
sudoers, `/etc/ld.so.preload`, shell start-up files, processes running from memory, temp
directories or deleted files, processes pretending to be kernel threads, **shells and tools started
by the web apps, nginx, MySQL or Forgejo**, unexpected listeners and outbound connections, cron
and systemd persistence, executables in `/tmp` `/var/tmp` `/dev/shm`, kernel taint and modules,
whether auditd, Wazuh, Suricata, fail2ban, UFW and logging still run, the app `.env` file
permissions, scripts in static/upload directories, uncommitted changes in app checkouts, and
`dpkg --verify` of the core packages (sshd, sudo, PAM, coreutils, procps, ...).

### Read the findings

- **HIGH**: a strong sign of compromise, or a configuration that changes the scope (see below).
  One unexplained HIGH is enough to treat this as an incident.
- **MED**: needs an explanation. Many are normal right after provisioning or a deployment
  ("changed in the last 14 days"); compare with what you did and when.
- **INFO**: context for the investigation (who logged in from where, which accounts exist).

Known benign findings: deleted programs still running after an unattended upgrade (until the
service restarts); config files changed by the provisioning (`dpkg --verify` lists them with `c`);
`git` with a login shell (Forgejo); files changed in the window if you provisioned or deployed then.

A clean triage does **not** prove the server is clean: root can hide from every local check.
If the alert that started this came from the Wazuh manager or from outside, believe the alert.

### Severity

| Level | Examples | Response |
|---|---|---|
| **SEV1** – root or data breach | Root shell by an attacker, changed system binaries, UID 0 account, data exfiltration, server attacking others | Full procedure now; rebuild; rotate everything; assess notification |
| **SEV2** – app compromise | Webshell, code execution as the app user, unknown admin in the app or Forgejo, app database read | Full procedure; rebuild; rotate everything the app user could read. **If the app user has sudo rights, treat as SEV1** (see below) |
| **SEV3** – suspicious, unconfirmed | Unexplained MED findings, a Suricata alert without follow-up, odd login time from a known IP | Collect, investigate; decide within hours; contain if not explained |
| **SEV4** – noise | Scans, brute force against SSH that fail2ban blocks, 404s for `/wp-admin` | Note it; no action |

> **Scope trap on this stack:** the provisioning gives the sudo user `NOPASSWD` for
> `/usr/bin/systemctl` (and apt-get), and `systemctl` with root rights is root-equivalent (a
> unit can run anything as root). If a web app's gunicorn service runs as that same user (the
> clone script puts apps in `/home/<user>/<domain>` and runs them as `User=<user>`), **code
> execution in the app is a root compromise**. Triage reports this as
> `Web app ... runs as '<user>', who is in the sudo group / has NOPASSWD sudo rules`.

### Scope questions

Answer these in the incident log, even with "unknown":

- What level did the attacker reach: app user, another account, root?
- Is it still active (processes, connections, recent changes)?
- Which data could it read: app databases (personal data?), `.env` secrets, Forgejo repositories?
- Which **other** systems could it reach from here: SSH keys on this server, API tokens, the
  Forgejo repositories that deploy to other servers, the backup target?
- Since when? (first guess now, refined in the investigation)

---

## 3. Containment

Contain in this order. Each step loses less evidence than the next.

### 3.1 Provider snapshot

Take a disk snapshot in the provider panel now (some providers can include RAM). Note its ID and
time in the log. It is the best evidence you will have and lets you look again later.

### 3.2 Volatile evidence (2 minutes)

```bash
sudo bash ~/ubuntu_incident_response.sh collect
```

`collect` starts with the volatile data (processes with their programs, command lines, working
directories and open files, all network connections, firewall, sessions, kernel modules) and keeps
a copy of every program that is deleted or runs from a temp or home directory: that is often the
malware itself (`volatile/exe/`, mode 400, never run it). If you are in a hurry, you can stop it with
Ctrl-C after the `Volatile data` section and run it again later (it adds to the same case).

**Memory dump (optional):** for a SEV1 where you may need professional forensics, capture RAM
before containment with [AVML](https://github.com/microsoft/avml) (a static binary). Copy it from
your workstation, write the dump to a volume attached for that purpose (it is as big as the RAM),
then delete the binary. Note: `/dev/shm` and `/run/shm` are mounted `noexec` by the provisioning.

### 3.3 Cut the network

**Best: the provider's firewall**, because root on the server cannot change it. Allow only SSH
from your admin IP and outbound to the Wazuh manager (1514/tcp, 1515/tcp); block everything else in
and out.

**On the server (in addition, or if the provider has no firewall):**

```bash
sudo bash ~/ubuntu_incident_response.sh contain network --admin-ip 198.51.100.7
```

This saves `/etc/ufw` and `/etc/default/ufw` to the case directory, adds SSH from the admin IPs
and outbound to the Wazuh manager (read from `ossec.conf`, or `--wazuh-manager`), sets the defaults
to deny in **and** out, removes all other rules, and then kills established connections to other
addresses (`ss -K`): a reverse shell that is already connected survives a firewall change. It refuses
to run if your own SSH session's address is not in `--admin-ip` (use `--console` if you are on the
provider console). **Test a new SSH login from a second terminal before you close the first.**

The web sites go offline, and DNS, apt and outgoing mail stop. The Wazuh agent keeps its connection;
if it reconnects by host name it needs DNS, so give the manager by IP (`--wazuh-manager 192.0.2.10`).

`sudo bash ~/ubuntu_incident_response.sh contain undo-network` restores the firewall as it was
before the first containment of this case (for a false alarm).

### 3.4 Other containment actions (as needed)

| Command | Effect | Evidence cost |
|---|---|---|
| `contain webapps` | **Freezes** the gunicorn services (cgroup freezer): processes stay in memory but do nothing; nginx answers 502/timeouts | None (`undo-webapps` thaws them) |
| `contain webapps --stop` | Stops them | Process memory is lost |
| `contain user NAME` | Locks the password, expires the account, moves `authorized_keys` aside (copy in the case), ends sessions, kills the user's processes | Processes of that user are lost; refuses to lock you or root |
| `contain cron` | Stops cron and atd (persistence that re-runs every minute) | None; your own jobs (backups, AIDE, blocklist) stop too |
| `contain status` | Shows what is contained | – |

All `contain` actions ask for confirmation (or `--yes`) and warn when no volatile evidence was
collected first.

### 3.5 Revoke credentials the attacker can use elsewhere, now

Most secrets are rotated during the rebuild. Rotate these **immediately**, because the attacker can
use them from anywhere and the damage grows while you investigate:

- Keys and tokens on this server that open **other** systems: SSH private keys in `~/.ssh` that are
  authorized on other servers or on Forgejo/GitHub, cloud/DNS/backup API tokens. (`secrets` lists
  the private keys it finds and the hosts in `known_hosts`.)
- The SMTP relay password (`/etc/postfix/sasl_passwd`) if spam is going out.
- Payment and other third-party API keys from the `.env` files if the app user or root was reached.
- The provider account password if it, or an API token, was ever on the server.

Do this from your workstation, at the provider's side. Write each one into the log.

### 3.6 Notification (start the clock)

If personal information may have been accessed (app user data, customer emails, password hashes),
a privacy breach may be notifiable under the NZ Privacy Act 2020: if it has caused or is likely to
cause serious harm, the Privacy Commissioner and affected people must be told as soon as
practicable, and the Commissioner expects notification within 72 hours of becoming aware. Use the
[NotifyUs](https://www.privacy.org.nz/notifyus) tool to assess it; you can notify incrementally
and add details later. Check contractual duties to your customers, and GDPR if EU residents are
affected. Reporting to the [NCSC](https://www.ncsc.govt.nz/report/) (0800 114 115, formerly CERT NZ)
is voluntary and gets you advice. Record each decision **and its reason** in the log, including a
decision not to notify.

---

## 4. Investigation

### 4.1 Collect and run the checks

```bash
sudo bash ~/ubuntu_incident_response.sh collect        # if not done yet; adds to the same case
sudo bash ~/ubuntu_incident_response.sh investigate --since 30
```

`--since DAYS` (default 14) is the look-back window. Widen it until the earliest suspicious event
is well inside the window.

`collect` saves, after the volatile data:

| Directory | Content |
|---|---|
| `logs/` | `/var/log` (incl. rotated, binary journal, Suricata `eve.json`, nginx, auth, audit, MySQL error log), Wazuh agent logs, Forgejo log, the apps' `log/` directories; a text export of the journal; shell histories of all accounts; `last`, `lastb`, `lastlog`. Single files over `--max-log-mb` (1024) are listed with their sha256 instead |
| `config/` | `/etc`, crontabs, Wazuh agent config, `/usr/local` scripts, dotfiles and `authorized_keys`/`known_hosts` of all accounts, `nginx -T`, `sshd -T`, audit rules, package list, apt history. **Without secrets** by default: `config/secrets_manifest.txt` lists every left-out file with owner, mode, times and sha256 (compare with your backup to see if it was changed) |
| `apps/<domain>/` | The app directory without venv, `.git` and logs; sha256 of **every** file including the venv; listing with times; the systemd unit; `git status`/`log`/`diff` (run as the directory's owner with repository-configured programs disabled) |
| `timeline/bodyfile.txt.gz` | A file system timeline of all local file systems in Sleuth Kit bodyfile format |

`--include-secrets` also copies the secret files and every process environment (which holds the
`.env` values of the apps). Only use it if the evidence goes to someone who must see them, and
encrypt the export.

`investigate` adds (in `investigate/`, findings in `findings.txt`):

- `dpkg --verify` of **all** packages, files in system directories no package owns, unowned
  SUID/SGID files
- **pip RECORD verification of every virtualenv** (and `/usr/local/lib/python3*`): changed package
  files, `.pth`/`sitecustomize.py` start-up hooks that pip did not install (a favourite Python backdoor)
- every file changed in the window, sorted by ctime (`changed_files_important.txt` for system, config
  and home directories; per app in `apps/<domain>/changed_files.txt`)
- SSH logins, sudo commands, user/group/password changes, `su`
- nginx: top clients, POST paths, 5xx, responses over 5 MB, attack-pattern requests, and **those that
  got a 2xx/3xx answer** (`web/suspicious_requests_successful.txt`: the interesting ones)
- Suricata alerts in the window, top signatures and sources, **alerts with this server as the source**
- auditd reports and the Neo23x0 rule keys, program starts by the web app users
- MySQL accounts and grants (no hashes), UDFs, triggers, events, routines, `secure_file_priv`, binlogs
- Forgejo (SQLite opened read-only): users and admins, SSH and deploy keys, access tokens, webhooks,
  OAuth apps, runners, with RECENT marks; server-side git hooks; non-Forgejo keys in git's `authorized_keys`
- apt hooks, udev `RUN`, modprobe `install`, MOTD scripts, library paths, git hooks in app checkouts,
  nginx upstreams that are not local

Work through `findings.txt` from the top. Each finding names the file that has the details.

### 4.2 The questions to answer

| Question | Where to look |
|---|---|
| **Entry point** | nginx `suspicious_requests_successful.txt` and `top_post_paths.txt`; app tracebacks in `logs/` (the exploit attempt often throws errors first); Suricata alerts against port 443; SSH logins (`triage/ssh_logins.txt`, `investigate/auth/`); Forgejo users/tokens; recently changed files in the app directory |
| **Earliest compromise time** | The first event in any of: unexpected login, webshell file mtime/ctime, first successful attack request, first suspicious process start (`volatile/ps_forest.txt` has start times), first Wazuh alert. Then look **before** it for reconnaissance from the same IP |
| **What they did** | Shell histories (`logs/history/`), sudo commands, auditd `execve` by the app user, process tree, timeline around the times found above |
| **Persistence** | cron, systemd units/timers/generators, `authorized_keys`, new accounts, `.pth` files in venvs, git hooks (app checkouts and Forgejo repositories), MOTD/profile scripts, `ld.so.preload`, changed packages |
| **Data access** | Large responses in nginx; MySQL general log/binlog (if enabled); app logs of exports and admin actions; outbound connections and Suricata outbound alerts; `/tmp` archives (`.zip`, `.sql`, `.tar.gz`) |
| **Lateral movement** | Private keys on the server (`secrets` lists them) and `known_hosts`; outbound SSH connections; auth logs on the other servers for logins from this server's IP; pushes to Forgejo repositories that deploy elsewhere |

**Compare with the Wazuh manager** for the same period: if the local logs have a gap or disagree,
the local logs were edited.

### 4.3 Useful manual commands

On the analysis workstation, after unpacking the export:

```bash
# file system timeline (Sleuth Kit: apt install sleuthkit)
zcat timeline/bodyfile.txt.gz > bodyfile.txt
mactime -b bodyfile.txt -d -z UTC 2026-11-01..2026-11-23 > timeline.csv
grep -E '/home/xlvisuals/|/etc/|/usr/(s)?bin/|/tmp/' timeline.csv | less

# all requests from one attacker IP, in order
tar -xzf logs/logs.tar.gz var/log/nginx
zgrep -h '^198\.51\.100\.66 ' var/log/nginx/access.log* | sort -k4 | less

# Suricata alerts for one IP
jq -c 'select(.src == "198.51.100.66" or .dst == "198.51.100.66")' investigate/suricata/alerts.jsonl

# compare the app files with a clean checkout of the deployed commit (paths in the list are absolute)
sed 's#  /home/xlvisuals/www.xlvisuals.com/#  #' apps/www.xlvisuals.com/all_files.sha256 > app.sha256
(cd /path/to/clean/checkout && sha256sum -c --quiet "$OLDPWD/app.sha256" | grep -v -E '/(venv|log)/')
```

On the server (read-only, before the rebuild):

```bash
# what did MySQL change (binary logging on): rows changed in a time range
sudo mysqlbinlog --base64-output=decode-rows -v --start-datetime="2026-11-20 03:00:00" \
     --stop-datetime="2026-11-20 05:00:00" /var/lib/mysql/binlog.0000* | less

# audit events of the app user (UID from 'id -u xlvisuals')
sudo ausearch -ua 1000 -ts 11/20/2026 03:00:00 -te 11/20/2026 05:00:00 -i | less

# app accounts with admin rights in the app's own database (adjust to your schema)
sudo mysql -e "SELECT id, email, role, created_at, updated_at FROM app.user WHERE role='admin' ORDER BY updated_at DESC"
```

### 4.4 Common entry points for this stack

- **The web app itself**: file upload that stores a script under `static/`, SQL injection in a raw
  `text()` query, server-side template injection, `pickle`/YAML deserialisation, a path traversal
  that reads `/proc/self/environ` (the gunicorn environment holds the `.env` values), SSRF to
  local services (Valkey, Forgejo, Monit on 127.0.0.1)
- **Leaked secrets**: an `.env` or a key committed to a repository; `SECRET_KEY` reused across
  apps lets an attacker forge sessions in all of them
- **A stolen SSH key** from a developer machine (logins from an unknown IP with a known key)
- **Forgejo**: a weak or reused password, an outdated version, a malicious push to a repository
  that the server deploys from
- **Outdated packages** (a held package, or a reboot that never happened: `reboot-required-check`)

### 4.5 Decide the clean point

Write down: **earliest compromise time = T** (with your confidence and the evidence). Then:

- **Code**: from a known-good source, not from this server and not from Forgejo on this server
  unless you have verified the history (compare with developers' clones; look for unexpected
  commits, force-pushes, changed tags).
- **Database**: the last backup **before T**. Data entered after T is lost unless you replay it
  from the binlog or export it from the old server **after** reviewing it. Even a pre-T backup can
  contain attacker changes from before you think T was: review admin accounts, password/email
  changes and stored HTML in the restored database.
- **Config**: the provisioning conf files and this repository, not the config backup (see 6).

---

## 5. Export

```bash
sudo bash ~/ubuntu_incident_response.sh export --encrypt-to ~/ir_pub.asc
```

`export` refreshes `MANIFEST.sha256` (sha256 of every file in the case), packs the case directory,
encrypts it with GPG to the given public key (if encryption fails, no archive is left behind),
writes a `.sha256` next to it, moves both to your home directory and logs the archive's hash in
`case.log`. **Write the sha256 into the incident log immediately.**

```bash
# on the workstation
scp you@203.0.113.10:'~/<host>_<time>_*.tar.gz.gpg*' .
sha256sum -c <host>_<time>_*.tar.gz.gpg.sha256
gpg -d <host>_<time>_*.tar.gz.gpg | tar -xzf -
cd <host>_<time> && sha256sum -c --quiet MANIFEST.sha256
```

Then delete the archive on the server (`shred -u ~/<host>_*`).

- **Store** two copies on encrypted, offline media. Keep them at least until the incident is
  closed and any notification or legal process is finished (ask your lawyer how long).
- **Chain of custody**: `case.log` records who ran which command, from which SSH address, with
  which script hash, and the manifest hash after each step. Add to the incident log who copied the
  archive where, and when.
- **Before sharing** with a third party: the case contains shell histories (may contain typed
  passwords), log files with personal data (IP addresses, emails in URLs), and the app source code.
  Secrets are only in it with `--include-secrets`.

Shortcut for all read-only steps in one go: `sudo bash ~/ubuntu_incident_response.sh all`
(triage, collect, investigate, secrets, export; never contains).

---

## 6. Eradication & recovery (rebuild)

Build the replacement **while the old server stays contained**, then switch.

1. **Fix the entry point first** (in the code, the configuration or the process). Otherwise the
   new server falls the same way.
2. **New VPS**, ideally with a new IP address. Provision it from a **trusted** copy of this
   repository (from GitHub or your workstation, not from the compromised server or its Forgejo),
   with your saved `ubuntu_provision.conf`. New passwords are prompted.
3. **New SSH key pair** for the admin user if there is any doubt about the old one.
4. **Restore selectively.** The config tarball from `ubuntu_backup_config.sh` is a reference, not a
   restore source: **do not restore** `/etc/shadow`, `/etc/passwd`, `/etc/group`, `/etc/sudoers*`,
   `/etc/ssh` (host keys), any `authorized_keys`, `/etc/letsencrypt`, `/var/ossec/etc/client.keys`,
   `/etc/postfix/sasl_passwd`, `/etc/monit/monitrc`, `/etc/mysql/debian.cnf`, the secrets in
   `/etc/forgejo/app.ini`, `/etc/grafana/grafana.ini`, `/etc/livekit`, cron jobs or systemd units
   without diffing them against the repository first, or **any backup taken after T**.
5. **App code** from the verified source; build the virtualenv fresh from the requirements (do not
   copy the old `venv/`). `ubuntu_clone_server.sh` must not use the compromised server as its source.
6. **Database** from the clean backup; review it (4.5).
7. **Forgejo**: restore repositories from verified copies, then review users, keys, tokens,
   webhooks and hooks (`investigate/forgejo/db_report.txt` shows what existed).
8. **Rotate every secret.** Work through `secrets/rotation_checklist.md` from the case; it lists,
   for this server:
   - each `.env` variable name per app, classified as secret or not (values are never shown)
   - MySQL accounts, Linux accounts with passwords
   - private keys found on the server, the SSH targets they open, credential files (`.my.cnf`,
     `.netrc`, `.git-credentials`, cloud configs)
   - TLS certificates to **revoke** (`certbot revoke --cert-name <name> --reason keycompromise`)
     and issue anew
   - the Wazuh agent key (remove the old agent on the manager, enroll the new server fresh)
   - SMTP relay, Monit, Forgejo (`SECRET_KEY`, `INTERNAL_TOKEN`, `JWT_SECRET`, `LFS_JWT_SECRET`,
     user passwords, tokens), Grafana, LiveKit, Valkey, Mosquitto
   - outside the server: provider account, registrar and DNS, backup storage, third-party APIs

   **Order**: the accounts that control everything else first (provider, registrar/DNS, email of
   the admin, password manager if it was ever unlocked near the server), then SSH keys, then the
   service and app secrets. Rotating `SECRET_KEY` logs every app user out (intended); also revoke
   API tokens and remember-me tokens stored in the app databases, and force password resets if the
   database may have been read.
9. **Enroll the new server in Wazuh**, check Suricata, auditd and AIDE run (`ubuntu_health_check.sh`),
   then switch DNS.
10. **Watch closely for 30 days**: Wazuh alerts for the new server, logins, outbound traffic, and
    the same attack pattern against the new server.
11. **Destroy the old VPS** only after the evidence is exported and verified and the snapshot is
    kept for as long as you decided in 5. Delete its snapshot when that period ends.

---

## 7. After the incident

Within two weeks, write a short report (what happened, timeline, root cause, what worked, what did
not) and turn the lessons into changes. For this stack, typical ones:

- Run each web app as its **own** unprivileged user without sudo; give the admin user sudo with a
  password only (`NOPASSWD: /usr/bin/systemctl` is root-equivalent).
- Keep app code read-only for the app user (owned by root or a deploy user); only upload and data
  directories writable, and nginx must never execute anything from them.
- Move Forgejo to its own server so an app compromise does not reach the source of every deployment.
- Longer log retention on the Wazuh manager; alerts for "agent disconnected" and for auditd/Suricata stopping.
- Add the missed signal to `howto/security_checklist.md`.

---

## Script reference

```
sudo bash ubuntu_incident_response.sh <command> [options]
```

| Command | Changes the server? | Purpose |
|---|---|---|
| `triage` | No | Quick checks, HIGH/MED/INFO findings |
| `collect` | No (writes the case directory) | Volatile data, logs, config, apps, timeline |
| `investigate` | No | Deep checks (packages, venvs, changed files, logs, DB, Forgejo) |
| `secrets` | No | Rotation checklist (names/paths only) |
| `contain network` / `undo-network` | **Yes** | Isolate to SSH from admin IPs + Wazuh / restore |
| `contain webapps` / `undo-webapps` | **Yes** | Freeze (or `--stop`) gunicorn services / thaw |
| `contain user NAME` | **Yes** | Lock account, disable keys, kill sessions |
| `contain cron` | **Yes** | Stop cron and atd |
| `contain status` | No | Show containment state |
| `export` | No (writes the archive) | tar.gz + sha256, optional GPG |
| `all` | No | triage, collect, investigate, secrets, export |

| Option | Default | Meaning |
|---|---|---|
| `--case DIR` | newest `/root/ir/*`, or new | Case directory; all commands add to the same case |
| `--new-case` | | Start a new case |
| `--since DAYS` | 14 | Look-back window |
| `--app-root DIR` | `/home/xlvisuals` | Parent of the web app directories |
| `--env-dir DIR` | `/etc/xlvisuals` | Location of the `.env` files |
| `--admin-ip LIST` | | IPs/CIDRs you administer from; required for `contain network` |
| `--console` | | You have the provider console: allow actions that could cut your SSH session |
| `--wazuh-manager H` | from `ossec.conf` | Manager kept reachable by `contain network` |
| `--keep-connections` | | `contain network` without killing established connections |
| `--stop` | | `contain webapps` stops instead of freezing |
| `--include-secrets` | | `collect` also copies secret files and process environments |
| `--max-log-mb N` | 1024 | Larger single log files are hashed, not copied |
| `--no-timeline` | | Skip the bodyfile timeline |
| `--encrypt-to FILE` | | GPG public key file for `export` |
| `--yes` | | No confirmation for `contain` (input is still checked) |

Environment overrides: `IR_EXPECTED_PORTS` (public listeners that are not flagged, default
`22/tcp 80/tcp 443/tcp 443/udp 68/udp 7881/tcp 3478/udp`, plus UDP ≥ 50000 when LiveKit is
installed) and `IR_NORMAL_OUT_PORTS` (outbound ports that are not flagged, default
`53 80 123 443 465 587 1514 1515`).

How it fails closed: unknown options and invalid values abort; a case directory must be new, empty
or carry the `.ir_case` marker; `contain network` refuses without `--admin-ip` covering your SSH
address, without UFW, or when the Wazuh manager cannot be resolved; a web app that cannot be frozen
is left alone rather than stopped; a service without `User=` counts as running as root; secrets
stay out of the evidence unless asked for; a failed encryption leaves no plaintext archive.

Case directory layout:

```
/root/ir/<host>_<UTC time>/
  .ir_case  README.txt  case.log  findings.txt  MANIFEST.sha256
  triage/        quick-check raw output
  volatile/      processes, network, sessions, modules; proc/ details; exe/ copies of suspicious programs
  logs/          logs.tar.gz, journal text export, history/, last/lastb/lastlog
  config/        etc.tar.gz (without secrets), secrets_manifest.txt, home/, nginx -T, sshd -T, packages
  apps/<domain>/ files.tar.gz, all_files.sha256, listing.txt, unit files, git status/diff
  timeline/      bodyfile.txt.gz
  investigate/   package/venv integrity, changed files, auth/, web/, suricata/, audit/, mysql/, forgejo/, persistence/
  secrets/       rotation_checklist.md
  containment/   firewall backups, killed connections, disabled keys
```
