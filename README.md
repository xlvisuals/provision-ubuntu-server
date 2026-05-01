# Ubuntu Server Provisioning

An interactive Bash provisioning script for **Ubuntu 24.04 LTS** and **Ubuntu 26.04 LTS** Server to 
quickly provision a secure webserver with Auditd, Fail2Ban, Forgejo, Grafana, Monit, Mosquitto, MySQL, Nginx, Postfix, PostgreSQL, Suricata, Valkey, Wazuh Agent, Webmin.
The script is re-entrant, but best run on a fresh **minimized** or **standard** install.
Every component is optional — you choose what gets installed and configured at runtime via interactive prompts.


---

## Requirements

| Requirement | Detail |
|---|---|
| OS | Ubuntu 24.04 LTS or 26.04 LTS Server (minimized or standard) |
| Disk space | 8 GB (minimized install) · 12 GB (standard install) |
| Privileges | Must be run as root (`sudo`) |
| Network | Active internet connection |

---

## Files

| File | Description |
|------|-------------|
| `ubuntu_provision.sh` | Main provisioning script |
| `ubuntu_provision.conf` | Configuration file (passwords omitted — prompted at runtime) |
| `ubuntu_backup_config.sh` | Backs up all service configurations to a timestamped tarball |
| `etc/` | Service configuration templates with `%%PLACEHOLDER%%` variables |

All files must sit in the same directory. The script uses its own location as the root for config templates and the backup script.

---

## Quick Start

To start, download the repository. If you have git available:
```
git clone https://github.com/xlvisuals/provision-ubuntu-server.git
cd provision-ubuntu-server-main
```

Or without git and unzip, e.g. on a fresh minimized Ubuntu Server installation:
```
wget https://github.com/xlvisuals/provision-ubuntu-server/archive/refs/heads/main.zip -O provision-ubuntu-server-main.zip
python3 -c "import zipfile; zipfile.ZipFile('provision-ubuntu-server-main.zip').extractall('.')"
cd provision-ubuntu-server-main
```

Then run ubuntu_provision.sh 

```bash
sudo bash ubuntu_provision.sh
```

Or with a configuration file to skip interactive prompts:

```bash
sudo bash ubuntu_provision.sh ubuntu_provision.conf
```

A timestamped log is written automatically to `/var/log/ubuntu_provision_<date>.log`.

> **After the script completes:** test SSH login in a *new* terminal window before closing the current session, then reboot to apply all changes.

---

## Configuration File

For automated or repeatable deployments, create `ubuntu_provision.conf` in the same directory as the script. Any variable set in the conf file will skip its interactive prompt. Variables left unset will still be prompted at runtime. Passwords are always prompted interactively and are never read from the conf file.

```bash
# ubuntu_provision.conf
# Passwords intentionally omitted - will be prompted

# Package versions
PG_VERSION=18
PYPY_VERSION=pypy3.11-v7.3.21-linux64

# INSTALL_DEFAULT sets the default for all INSTALL_ and CONFIGURE_ variables
# not explicitly set. Useful for targeted re-runs, e.g. just updating Postfix:
# INSTALL_DEFAULT=n
# INSTALL_POSTFIX=y

# User
USER_CREATE_SUDO_USER=y
USER_USE_CURRENT_USERNAME=n
USER_SUDO_USER_USERNAME=example

# System
CONFIGURE_LVM=y
LVM_DO_RESIZE=y
LVM_TARGET_GB=all
CONFIGURE_SWAP=y
SWAP_SIZE_GB=2
TUNE_SYSTEM=y
APT_DAILY_HOUR=10
APT_UPGRADE_HOUR=11
DISABLE_TX_OFFLOAD=n
CONFIGURE_APPARMOR=y
APPARMOR_ENABLE=y
APPARMOR_ENFORCE=y

# Packages
UNINSTALL_PACKAGES=y
UPDATE_PACKAGES=y
INSTALL_PACKAGES=y

# Services
INSTALL_UFW=y
INSTALL_SSH=y
INSTALL_FONTS=y
INSTALL_WEASYPRINT=y
INSTALL_IMAGEMAGICK=y
INSTALL_CPYTHON314=y
INSTALL_PYPY311=y
INSTALL_NGINX=y
INSTALL_VALKEY=y
INSTALL_MYSQL=y
INSTALL_POSTGRESQL=y
INSTALL_MOSQUITTO=y
INSTALL_POSTFIX=y
INSTALL_MONIT=y
INSTALL_WEBMIN=y
INSTALL_GRAFANA=y
INSTALL_FORGEJO=y
INSTALL_FAIL2BAN=y
INSTALL_AUDITD=y
INSTALL_IPBLOCK=y
INSTALL_SURICATA=y
INSTALL_WAZUH=y

# Fonts tuning
INSTALL_MS_FONTS=y

# MySQL tuning - leave blank to use auto-calculated defaults based on available memory
MYSQL_BUFFER_POOL_MB=
MYSQL_BUFFER_POOL_INSTANCES=
MYSQL_BUFFER_POOL_CHUNK_MB=128
MYSQL_MAX_CONNECTIONS=100
MYSQL_LOG_BUFFER_MB=64
MYSQL_BINLOG_CACHE_MB=16
MYSQL_JOIN_BUFFER_KB=512
MYSQL_SORT_BUFFER_KB=512
MYSQL_READ_BUFFER_KB=128
MYSQL_READ_RND_BUFFER_KB=1024
# Passwords intentionally omitted - will always be prompted:
# MYSQL_PASS=
# MYSQL_PASS_CONFIRM=

# PostgreSQL tuning - leave blank to use auto-calculated defaults based on available memory
PG_MAX_CONNECTIONS=100
PG_SHARED_BUFFERS_MB=
PG_WORK_MEM_MB=
PG_EFFECTIVE_CACHE_MB=
PG_MAX_WORKER_PROCESSES=
PG_MAX_PARALLEL_WORKERS=
PG_MAX_PARALLEL_WORKERS_PG=
PG_EFFECTIVE_IO_CONCURRENCY=100
# Password intentionally omitted - will always be prompted:
# PG_PASS=

# Postfix relay-only SMTP
POSTFIX_RELAY_HOST=smtp.example.com
POSTFIX_RELAY_PORT=587
POSTFIX_RELAY_USERNAME=user@example.com
POSTFIX_DOMAIN=example.com
POSTFIX_FROM_ADDRESS=root@example.com
POSTFIX_ROOT_ALIAS=admin@example.com
# Password intentionally omitted - will always be prompted:
# POSTFIX_RELAY_PASSWORD=

# Monit
MONIT_USE_POSTFIX=y
MONIT_MAILSERVER_HOST=smtp.example.com
MONIT_MAILSERVER_PORT=587
MONIT_MAILSERVER_USERNAME=monit@example.com
MONIT_ALERT_SENDER=monit@example.com
MONIT_ALERT_RECIPIENT=admin@example.com
MONIT_ADMIN_USERNAME=admin
# Passwords intentionally omitted - will always be prompted:
# MONIT_MAILSERVER_PASSWORD=
# MONIT_ADMIN_PASSWORD=

# Grafana
GRAFANA_USE_POSTFIX=y
GRAFANA_SMTP_ENABLED=true
GRAFANA_SMTP_HOST=smtp.example.com
GRAFANA_SMTP_PORT=587
GRAFANA_SMTP_USER=grafana@example.com
GRAFANA_SMTP_FROM_ADDRESS=grafana@example.com
GRAFANA_SMTP_FROM_NAME=Grafana
GRAFANA_SMTP_EHLO_IDENTITY=example.com
GRAFANA_SMTP_STARTTLS_POLICY=MandatoryStartTLS
# Password intentionally omitted - will always be prompted:
# GRAFANA_SMTP_PASSWORD=

# Forgejo
FORGEJO_DOMAIN=example.com
FORGEJO_PORT=3030
FORGEJO_USE_POSTFIX=y
FORGEJO_MAILER_ENABLED=true
FORGEJO_SMTP_ADDR=smtp.example.com
FORGEJO_SMTP_PORT=587
FORGEJO_SMTP_FROM=forgejo@example.com
FORGEJO_SMTP_USER=forgejo@example.com
# Password intentionally omitted - will always be prompted:
# FORGEJO_SMTP_PASSWORD=

# Wazuh
WAZUH_MANAGER=wazuh.example.com
```

> **Note:** Keep the conf file out of public repositories — it contains usernames and hostnames. Passwords are always prompted interactively and never stored in the conf file.

---

## What It Does

The script walks you through each step with a `y/n` prompt. If a `ubuntu_provision.conf` file is provided, those values are used automatically and the corresponding prompts are skipped.

### System Configuration

| Step | Description |
|---|---|
| Backup | Full config snapshot taken before prompting and again before applying changes, via `ubuntu_backup_config.sh` |
| Timezone | Set to UTC |
| LVM | Optionally resize LVM root volume to a target size or 100% of the volume group |
| Swap | Creates a configurable swap file if none exists |
| User | Creates a new sudo user or configures an existing one; sets up SSH key access |
| Uninstall | Removes unneeded packages (`modemmanager`, `snapd`, `bluetooth`, `apport`, etc.) |
| Updates | Full system upgrade via `apt-get full-upgrade` |
| UFW Firewall | Default deny inbound, allow outbound; opens ports 22, 80, 443 as appropriate |
| SSH Hardening | Key-only authentication, no root login, restricted `AllowUsers`, `MaxAuthTries 3` |
| Sudo | 60-minute `timestamp_timeout`; NOPASSWD for `apt-get`, `systemctl`, `reboot`, and the health check script |
| Update Timers | Unattended-upgrades scheduled at prompted UTC hours (apt update runs twice daily, 12 hours apart) |
| File Limits | `nofile` and `nproc` raised via a drop-in in `limits.d` |
| Kernel Tuning | `sysctl` hardening — swap tuning, ICMP redirect blocking, IP spoofing prevention, kernel pointer/dmesg restrictions |
| Shared Memory | `/run/shm` mounted `nosuid,nodev,noexec` |
| TCP TX Offload | Optionally disables TCP transmit offloading on the primary interface via a systemd oneshot service |
| AppArmor | Optionally enables AppArmor, enforces available profiles, and sets installed services without profiles to complain mode |
| Ubuntu Pro | If not attached, disables Ubuntu Pro background services to reduce noise |

### Software Installed (all optional)

**Web Stack**

| Package | Default Port | Notes |
|---|---|---|
| Nginx | 80, 443 | |
| MySQL Server | 3306 | Tunable InnoDB parameters; auto-calculated from RAM if left blank |
| PostgreSQL 18 | 5432 | Tunable memory and parallelism parameters; auto-calculated from RAM/CPU if left blank |
| Valkey | 6379 | Redis-compatible cache |
| Mosquitto | 1883 | MQTT broker |

**Mail**

| Package | Notes |
|---|---|
| Postfix | Relay-only — accepts local mail and forwards to an external SMTP provider. Monit, Grafana, and Forgejo can each be configured to route through Postfix instead of providing individual SMTP credentials |

**Management & Monitoring**

| Package | Default Port | Notes |
|---|---|---|
| Webmin | 10000 | Installed via official `webmin-setup-repo.sh` |
| Monit | 2812 | |
| Grafana | 3000 | |
| Forgejo | 3000 (3030 if Grafana also installed) | Self-hosted Git |

**Runtimes**

| Package | Notes |
|---|---|
| Python 3.14 | Via deadsnakes PPA on Ubuntu 24.04; pre-installed on Ubuntu 26.04 |
| PyPy 3.11 | Installed to `/opt`, symlinked into `/usr/local/bin`; latest release fetched dynamically with hardcoded fallback |
| Weasyprint | PDF generation |
| ImageMagick | Image processing |
| Fonts | Liberation, FreeFonts, Microsoft core fonts (EULA pre-accepted) |

**Security**

| Package | Notes |
|---|---|
| Fail2Ban | Bans IPs after repeated failed SSH attempts |
| auditd | Kernel-level audit logging |
| Suricata IDS | Network intrusion detection; `community-id` enabled; rules updated via `suricata-update` |
| Wazuh Agent | SIEM agent; requires an existing Wazuh Manager; integrates Suricata and auditd logs |
| UFW IP Blocklist | Daily cron job pulls and applies an IP blocklist via `ipsum` |

**Tools**

`vim` · `nano` · `ne` · `micro` · `tmux` · `btop` · `ncdu` · `nmap` · `lynis` · `iftop` · `iotop` · `sysstat` · `mc` · `speedtest-cli` · `jq` · `git` · `git-lfs` · `curl` · `wget` · `rsync` · `dnsutils` · `lsof` · `unzip` · `zip` · `p7zip-full` · `net-tools` · `debsums` · `iputils-ping` · `needrestart` · `smartmontools` (bare metal only)

---

## Port Reference

| Service | Port | UFW |
|---|---|---|
| SSH | 22 | allowed |
| Nginx HTTP | 80 | allowed |
| Nginx HTTPS | 443 | allowed |
| MySQL | 3306 | blocked |
| PostgreSQL | 5432 | blocked |
| Valkey | 6379 | blocked |
| Mosquitto | 1883 | blocked |
| Postfix | 25 | blocked |
| Monit | 2812 | blocked |
| Grafana | 3000 | blocked |
| Forgejo (standalone) | 3000 | blocked |
| Forgejo (with Grafana) | 3030 | blocked |
| Webmin | 10000 | blocked |

---

## Config Templates

Service configuration files live in `etc/` mirroring the target filesystem layout:

```
etc/
  mysql/mysql.conf.d/mysqld.cnf
  nginx/nginx.conf
  nginx/sites-available/default
  postgresql/postgresql.conf
  postgresql/pg_hba.conf
  postfix/main.cf
  valkey/valkey.conf
  grafana/grafana.ini
  forgejo/app.ini
  monit/monitrc
  monit/conf-available/
  systemd/system/disable-offload.service
```

Files containing `%%PLACEHOLDER%%` variables are copied to the target path after all services are installed and substituted with `sed`. Files without placeholders are copied as-is.

### Postfix (`etc/postfix/main.cf`)

| Placeholder | Value |
|---|---|
| `%%POSTFIX_RELAY_HOST%%` | SMTP relay hostname |
| `%%POSTFIX_RELAY_PORT%%` | SMTP relay port |
| `%%POSTFIX_DOMAIN%%` | Mail domain (also written to `/etc/mailname`) |
| `%%POSTFIX_SERVER_HOSTNAME%%` | Server FQDN (auto-detected via `hostname -f`) |

`sasl_passwd`, `sender_canonical_maps`, `header_check`, and `generic` are written directly by the script using `POSTFIX_FROM_ADDRESS` — no templates needed for these.

### Disable TCP TX Offload (`etc/systemd/system/disable-offload.service`)

| Placeholder | Value |
|---|---|
| `%%PRIMARY_INTERFACE%%` | Auto-detected primary network interface |

### PostgreSQL (`etc/postgresql/postgresql.conf`)

| Placeholder | Value |
|---|---|
| `%%PG_MAX_CONNECTIONS%%` | max_connections |
| `%%PG_SHARED_BUFFERS%%` | shared_buffers (e.g. `256MB`) |
| `%%PG_WORK_MEM%%` | work_mem |
| `%%PG_EFFECTIVE_CACHE_SIZE%%` | effective_cache_size |
| `%%PG_MAX_WORKER_PROCESSES%%` | max_worker_processes |
| `%%PG_MAX_PARALLEL_WORKERS%%` | max_parallel_workers |
| `%%PG_MAX_PARALLEL_WORKERS_PG%%` | max_parallel_workers_per_gather |
| `%%PG_EFFECTIVE_IO_CONCURRENCY%%` | effective_io_concurrency |

A `pg_hba.conf` template is also required at `etc/postgresql/pg_hba.conf`.

### Monit (`etc/monit/monitrc`)

| Placeholder | Value |
|---|---|
| `%%MONIT_HOST_NAME%%` | Automatically set from `hostname -f` |
| `%%MONIT_MAILSERVER_HOST%%` | Mail server hostname (`localhost` if via Postfix) |
| `%%MONIT_MAILSERVER_PORT%%` | Mail server port (`25` if via Postfix) |
| `%%MONIT_MAILSERVER_USERNAME%%` | Mail server username (empty if via Postfix) |
| `%%MONIT_MAILSERVER_PASSWORD%%` | Mail server password (empty if via Postfix) |
| `%%MONIT_ADMIN_USERNAME%%` | Monit web UI username |
| `%%MONIT_ADMIN_PASSWORD%%` | Monit web UI password |
| `%%MONIT_ALERT_SENDER%%` | Alert sender address |
| `%%MONIT_ALERT_RECIPIENT%%` | Alert recipient address |

`monitrc` is set to `chmod 600` since it contains plaintext credentials.

### Grafana (`etc/grafana/grafana.ini`)

| Placeholder | Value |
|---|---|
| `%%GRAFANA_RANDOM_SECRET%%` | Auto-generated random secret key |
| `%%GRAFANA_SMTP_ENABLED%%` | `true` or `false` |
| `%%GRAFANA_SMTP_HOST%%` | SMTP host (`localhost` if via Postfix) |
| `%%GRAFANA_SMTP_PORT%%` | SMTP port (`25` if via Postfix) |
| `%%GRAFANA_SMTP_USER%%` | SMTP username (empty if via Postfix) |
| `%%GRAFANA_SMTP_PASSWORD%%` | SMTP password (empty if via Postfix) |
| `%%GRAFANA_SMTP_FROM_ADDRESS%%` | From address |
| `%%GRAFANA_SMTP_FROM_NAME%%` | From name |
| `%%GRAFANA_SMTP_EHLO_IDENTITY%%` | EHLO identity (empty if via Postfix) |
| `%%GRAFANA_SMTP_STARTTLS_POLICY%%` | `NoConfig` if via Postfix, else `MandatoryStartTLS` |

### Forgejo (`etc/forgejo/app.ini`)

| Placeholder | Value |
|---|---|
| `%%FORGEJO_DOMAIN%%` | Domain name or IP (defaults to server's primary IP) |
| `%%FORGEJO_PORT%%` | HTTP port (3000, or 3030 if Grafana also installed) |
| `%%FORGEJO_MAILER_ENABLED%%` | `true` or `false` |
| `%%FORGEJO_SMTP_ADDR%%` | SMTP host (empty if via Postfix) |
| `%%FORGEJO_SMTP_PORT%%` | SMTP port (empty if via Postfix) |
| `%%FORGEJO_SMTP_FROM%%` | From address |
| `%%FORGEJO_SMTP_USER%%` | SMTP username (empty if via Postfix) |
| `%%FORGEJO_SMTP_PASSWORD%%` | SMTP password (empty if via Postfix) |

---

## Backup Script

`ubuntu_backup_config.sh` captures a full snapshot of service configs, users, SSH keys, cron jobs, systemd overrides, APT sources and GPG keys, Let's Encrypt certificates, and the Grafana and Forgejo databases.

```bash
sudo ./ubuntu_backup_config.sh [identifier]
```

If no argument is supplied, the server's IP address is used as the identifier. Output is a timestamped tarball in the current directory:

```
ubuntu_config_<identifier>_<date>.tar.gz
```

The provisioning script calls this automatically twice:

1. **Before prompting** — baseline snapshot of the machine as found
2. **After prompting, before applying** — snapshot taken immediately after the operator confirms the printed configuration, before any changes are made

---

## Health Check

After provisioning, a custom health check script is generated at:

```
/home/<username>/ubuntu_health_check.sh
```

Run it any time (as root) to get a colour-coded status report covering SSH config, swap settings, UFW state, and every installed service.

```bash
sudo ~/ubuntu_health_check.sh
```

---

## Notes

- **Idempotent-friendly:** the script detects already-installed services and prompts to `reinstall` rather than blindly overwriting. On re-runs, services that were skipped are still detected as installed and their configs updated.
- **`INSTALL_DEFAULT`:** set this in the conf file to apply a default `y` or `n` to all `INSTALL_` and `CONFIGURE_` variables not explicitly set. Useful for targeted re-runs — e.g. `INSTALL_DEFAULT=n` with `INSTALL_POSTFIX=y` to update only Postfix.
- **SSH lockout prevention:** if you choose to harden SSH, the script requires a valid public key before proceeding — it will abort rather than risk locking you out.
- **Postfix:** configured as relay-only (`inet_interfaces = 127.0.0.1`). Does not accept external mail. Rewrites all outgoing sender addresses to `POSTFIX_FROM_ADDRESS` via `sender_canonical_maps`, `header_check`, and `generic`. SASL credentials are written to `sasl_passwd`, hashed with `postmap`, and the plaintext file is deleted immediately. `mydestination` is set to localhost only — the mail domain must not appear there or Postfix will try to deliver locally instead of relaying.
- **Monit / Grafana / Forgejo:** if Postfix is installed, each service is offered the option to route mail through it (`localhost:25`) instead of providing individual SMTP credentials.
- **AppArmor:** enabled and set to enforce mode for profiles that exist on disk (`mysqld`, `rsyslogd`, `mosquitto` on Ubuntu 26.04). Services without profiles (`nginx`, `postgresql`, `postfix`, `grafana`, `forgejo`) are set to complain mode automatically so `aa-logprof` can build profiles from real usage. Run `sudo aa-logprof` after normal use, then `sudo aa-enforce` to activate.
- **Ubuntu Pro:** if the server is not attached to Ubuntu Pro, background Pro services (`ubuntu-pro-esm-cache`, `ubuntu-pro-apt-news`) are disabled to prevent AppArmor noise and unnecessary resource use.
- **TCP TX offloading:** disabled via a systemd oneshot service on the primary interface. Resolves edge cases where high dashboard load in Grafana causes CPU spikes from software checksumming.
- **smartmontools:** only installed on bare metal (`systemd-detect-virt` returns `none`). Skipped silently on virtual machines.
- **Wazuh:** requires an existing Wazuh Manager. The agent is configured to forward Suricata (`eve.json`) and auditd logs to the manager automatically.
- **Forgejo & Grafana:** if both are installed, Forgejo is shifted to port 3030 to avoid a conflict. On re-runs, the port is read from `/etc/forgejo/app.ini` if not set in the conf file.
- **PostgreSQL version** is pinned to 18 (configurable via `PG_VERSION` in the conf file or at the top of the script).
- **MySQL and PostgreSQL tuning** values are auto-calculated from available RAM and CPU at runtime if left blank in the conf file. `work_mem` is calculated as 25% of RAM divided by `max_connections`, floored at 4MB and capped at 16MB, since it is allocated per sort/hash operation and multiplies under concurrent load.
- **File limits:** `nofile` and `nproc` are set via a drop-in in `limits.d`. Note these only apply to PAM-authenticated sessions — systemd services use their own `LimitNOFILE` directives in their unit files.
- **Python venvs:** `setuptools` and `wheel` are not installed at the system level. Install them per-project inside a venv: `python3.14 -m venv /path/to/venv && pip install setuptools wheel`.
- **PyPy:** installed to `/opt` and symlinked into `/usr/local/bin`. The latest PyPy 3.11 release is fetched dynamically at install time, with a hardcoded fallback version if the fetch fails.
- **Webmin:** installed via the official `webmin-setup-repo.sh` script, which handles GPG keys and repo configuration automatically.

---

## Limitations

- Does not configure network interfaces or disk partitions beyond LVM resizing and swap creation.
- Does not back up or restore MySQL/PostgreSQL databases — only service configuration files.
- Requires internet access at runtime to download packages and (for Forgejo and PyPy) fetch the latest release version.
- `limits.conf` changes only apply to PAM-authenticated sessions. Services managed by systemd use their own `LimitNOFILE` directives in their unit files.
- All blocked services are only accessible via localhost or through Nginx as a reverse proxy.

---

## License

MIT — use freely, modify as needed.
