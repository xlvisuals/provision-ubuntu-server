# Ubuntu Server Provisioning

An interactive Bash provisioning script for **Ubuntu 24.04 LTS** and **Ubuntu 26.04 LTS** Server (minimized or standard) to 
quickly provision a hardened server and install any of the following services if desired: 

- Auditd<sup>*</sup>
- Fail2Ban<sup>*</sup>
- Forgejo
- Firewall<sup>*</sup>
- Grafana
- IP Blocklists<sup>*</sup>
- CIS Level 1 hardening<sup>*</sup>
- Kernel module blocklists<sup>*</sup>
- Monit<sup>*</sup>
- Mosquitto
- MySQL or MariaDB
- Nginx
- OpenSSH<sup>*</sup>
- Postfix
- PostgreSQL
- Suricata IDS<sup>*</sup>
- Valkey
- Wazuh Agent<sup>*</sup>
- Webmin

Every component is optional — you choose what gets installed and configured at runtime via interactive prompts. The script is re-entrant, but best run on a fresh  install. 
The components marked * are recommended.

---

## What It Does

The script walks you through each step with a `y/n` prompt. If a `ubuntu_provision.conf` file is provided, those values are used automatically and the corresponding prompts are skipped (See Configuration File section below).

Provision configuration files allow the fast and automated setup of different server configurations, for example for development, testing, production.

---

## Example Run

Below is a typical interactive session showing all prompts for a full installation. Values shown are examples — your defaults will vary based on detected system state and previously installed services.

```
Configure installation options:
Would you like to add a new sudo user? (y/n) : n
Use current user 'example'? (y/n) : y
Would you like to configure LVM disks? (y/n) : y
  LVM detected, but no free space remains in Volume Group. Skipping.
Would you like to configure swap space? (y/n) : y
  Active swap detected. No changes.
Would you like to tune the system? (y/n) : y
  Hour to run apt-get update (0-23) : 10
  Hour to run apt-get upgrade (0-23) : 11
Would you like to uninstall packages? (y/n) : y
Would you like to update packages? (y/n) : y
Would you like to install new packages? (y/n) : y
Would you like to configure ufw? (y/n) : y
Would you like to configure ssh? (y/n) : y
Would you like to install fonts? (y/n) : y
   Install Microsoft core fonts? (y/n) : y
Would you like to install weasyprint? (y/n) : y
Would you like to install imagemagick? (y/n) : y
Would you like to install Python 3.14? (y/n) : y
Would you like to install Pypy 3.11? (y/n) : n
Would you like to install nginx? (y/n) : y
  nginx worker processes? : 2
  Build the Coraza WAF module for nginx? (compiles from source, takes several minutes; NOT activated, see README) (y/n) : n
Would you like to install valkey? (y/n) : y
Would you like to install MySQL? (y/n) : n
Would you like to install MariaDB? (y/n) : y
  MariaDB root password : ********
  InnoDB buffer pool chunk size (MB) : 128
  InnoDB buffer pool instances (1-64) : 1
  Max connections : 100
  InnoDB log buffer size (MB) : 64
  Binlog cache size (MB) : 16
  Join buffer size (KB) : 512
  Sort buffer size (KB) : 512
  Read buffer size (KB) : 128
  Read rnd buffer size (KB) : 1024
Would you like to install PostgreSQL 18? (y/n) : y
  PostgreSQL superuser (postgres) password : ********
  Max connections : 100
  Available memory: 3868MB, CPU cores: 2
  Suggested: shared_buffers=967MB, work_mem=9MB, effective_cache_size=2320MB
  Shared buffers (MB) : 837
  Work mem (MB) : 8
  Effective cache size (MB) : 2010
  Max worker processes (= cores) : 2
  Max parallel workers (= cores) : 2
  Max parallel workers per gather (= cores/2) : 1
  Effective IO concurrency (SSD=100+, HDD=1) : 100
Would you like to install Mosquitto? (y/n) : y
Would you like to install Postfix (relay-only SMTP)? (y/n) : y
  SMTP relay host (mailserver address) : mail.example.com
  SMTP relay port : 587
  SMTP relay username : example@example.com
  SMTP relay password : ********
  Mail domain (used in From address) : example.com
  From address (e.g. root@domain.com) : example@example.com
  Forward local root mail to (root alias) : example@example.com
Would you like to install Monit? (y/n) : y
  Send Monit alerts via Postfix? (y/n) : y
  Alert sender address : monit@example.com
  Monit admin username : admin
  Monit admin password : ********
  Alert recipient address : example@example.com
Would you like to install Webmin? (y/n) : n
Would you like to install Grafana? (y/n) : y
  Send Grafana alerts via Postfix? (y/n) : y
  From address : grafana@example.com
  From name : Grafana
Would you like to install Forgejo? (y/n) : y
  Port 3000 is in use by Grafana. Enter Forgejo port : 3030
  Enter Forgejo domain or ip : 172.16.71.131
  Send Forgejo mail via Postfix? (y/n) : y
  From address : forgejo@example.com
Would you like to disable TCP transmit offloading? (y/n) : n
Would you like to install Fail2Ban? (y/n) : y
Would you like to install auditd? (y/n) : y
Would you like to install IP blocklist? (y/n) : y
Would you like to install Suricata IDS? (y/n) : y
Would you like to install Wazuh Agent? (y/n) : y
  Enter IP or Hostname of Wazuh Manager : 172.16.71.2
Would you like to configure AppArmor? (y/n) : y
  AppArmor status: installed=y, enabled=y, mode=enforce
  Enable AppArmor? (y/n) : y
  Set profiles to enforce mode? (y/n) : y
Blacklist unused kernel modules using modulejail? (y/n): y
Would you like to apply CIS Level 1 hardening? (y/n) : y
Would you like to create and run the Health Check script? (y/n) : y
Configuration complete.
```

---

## Quick Start

To start, download the repository. If you have git available:
```
git clone https://github.com/xlvisuals/provision-ubuntu-server.git
cd provision-ubuntu-server
```

Or without git and unzip, e.g. on a fresh minimized Ubuntu Server installation:
```
wget https://github.com/xlvisuals/provision-ubuntu-server/archive/refs/heads/main.zip -O provision-ubuntu-server.zip
python3 -c "import zipfile; zipfile.ZipFile('provision-ubuntu-server.zip').extractall('.')"
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


### System Configuration (optional)

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
| CIS Level 1 Hardening | Applies CIS Level 1 server benchmark controls: password policy (complexity, max age, history, lockout), PAM hardening (`nullok` removal, `pam_faillock`), account inactivity lock, umask `027`, `su` restricted to wheel group, system account shell lockdown, cron/at access control, SSH drop-in (ciphers, MACs, KEX, banner, `HostbasedAuthentication no`), sudo logfile, core dump disabling, additional sysctl hardening (ASLR, syncookies, martian logging, ICMP redirect, IPv6), kernel module blacklist (cramfs, hfs, hfsplus, jffs2, udf, usb-storage), `/dev/shm` mount options, journald→rsyslog forwarding, NTP configuration, session timeout (`TMOUT=900`), file integrity monitoring (AIDE, or Wazuh FIM if Wazuh is installed), and Postfix loopback-only binding. Controlled by `CONFIGURE_CIS_HARDENING`. |

### Software Installed (optional)

**Web Stack**

| Package        | Default Port | Notes                                                                                                    |
|----------------|---|----------------------------------------------------------------------------------------------------------|
| Nginx          | 80, 443 |                                                                                                          |
| Coraza WAF (nginx module) | — | Optional. Compiled from source, installed in detect-only mode and **not active** until enabled per site; see [Coraza WAF for nginx](#coraza-waf-for-nginx) |
| MySQL Server   | 3306 | Tunable InnoDB parameters; auto-calculated from RAM if left blank                                        |
| MariaDB Server | 3306 | Alternative to MySQL. Tunable InnoDB parameters; auto-calculated from RAM if left blank |
| PostgreSQL 18  | 5432 | Tunable memory and parallelism parameters; auto-calculated from RAM/CPU if left blank                    |
| Valkey         | 6379 | Redis-compatible cache                                                                                   |
| Mosquitto      | 1883 | MQTT broker                                                                                              |

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

| Package | Notes                                                                                                              |
|---|--------------------------------------------------------------------------------------------------------------------|
| Fail2Ban | Bans IPs after repeated failed SSH attempts                                                                        |
| auditd | Kernel-level audit logging                                                                                         |
| Suricata IDS | Network intrusion detection; `community-id` enabled; rules updated via `suricata-update`                           |
| Wazuh Agent | SIEM agent; requires an existing Wazuh Manager; integrates Suricata and auditd logs                                |
| UFW IP Blocklist | Daily cron job pulls and applies an IP blocklist via `ipsum`                                                       |
| modulejail | Shrink kernel-module attack surface by writing a modprobe.d blacklist for every kernel module not currently in use |

**Tools**

`vim` · `nano` · `ne` · `micro` · `tmux` · `btop` · `ncdu` · `nmap` · `lynis` · `iftop` · `iotop` · `sysstat` · `mc` · `speedtest-cli` · `jq` · `git` · `git-lfs` · `curl` · `wget` · `rsync` · `dnsutils` · `lsof` · `unzip` · `zip` · `p7zip-full` · `net-tools` · `debsums` · `iputils-ping` · `needrestart` · `smartmontools` (bare metal install only)


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

## Port Reference

| Service                | Port | Firewall status |
|------------------------|---|-----------------|
| SSH                    | 22 | **allowed**     |
| Nginx HTTP             | 80 | **allowed**         |
| Nginx HTTPS            | 443 | **allowed**         |
| MySQL                  | 3306 | blocked         |
| MariaDB                | 3306 | blocked         |
| PostgreSQL             | 5432 | blocked         |
| Valkey                 | 6379 | blocked         |
| Mosquitto              | 1883 | blocked         |
| Postfix                | 25 | blocked         |
| Monit                  | 2812 | blocked         |
| Grafana                | 3000 | blocked         |
| Forgejo (standalone)   | 3000 | blocked         |
| Forgejo (with Grafana) | 3030 | blocked         |
| Webmin                 | 10000 | blocked         |


---

## Configuration File

For automated or repeatable deployments, create `ubuntu_provision.conf` in the same directory as the script. Any variable set in the conf file will skip its interactive prompt. Variables left unset will still be prompted at runtime. Passwords are always prompted interactively and are never read from the conf file.

```bash
# ubuntu_provision.conf
# Passwords intentionally omitted - will be prompted

# Set to 'y' to skip confirmation question after configuration section
FORCE_APPLY=n

# Package versions
PG_VERSION=18
PYPY_FALLBACK_VERSION=pypy3.11-v7.3.22
FORGEJO_FALLBACK_VERSION=15.0.2
FORGEJO_FALLBACK_PORT=3030

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
LVM_RESIZE_VOLUME=y
LVM_RESIZE_TARGET_GB=all
CONFIGURE_SWAP=y
SWAP_SIZE_GB=2
TUNE_SYSTEM=y
AUTO_UPDATE_DAILY_HOUR=22
AUTO_UPGRADE_DAILY_HOUR=23
DISABLE_TX_OFFLOAD=n
CONFIGURE_APPARMOR=y
APPARMOR_ENABLE=y
APPARMOR_ENFORCE=y
CONFIGURE_MODULEJAIL=y
CONFIGURE_CIS_HARDENING=y
CREATE_HEALTHSCRIPT=y

# Packages
UNINSTALL_PACKAGES=y
UPDATE_PACKAGES=y
INSTALL_PACKAGES=y

# Services. MySQL and MariaDB are mutually exclusive. MySQL has precedence.
INSTALL_UFW=y
INSTALL_SSH=y
INSTALL_FONTS=y
INSTALL_WEASYPRINT=y
INSTALL_IMAGEMAGICK=y
INSTALL_CPYTHON314=y
INSTALL_PYPY311=y
INSTALL_NGINX=y
INSTALL_CORAZA=n
INSTALL_VALKEY=y
INSTALL_MYSQL=y
INSTALL_MARIADB=n
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

# MySQL/MariaDB tuning - leave blank to use auto-calculated defaults based on available memory
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
# MYSQL_PASSWORD=

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

> **Note:** Keep the conf file out of public repositories — it contains usernames and hostnames. Passwords are always prompted interactively and never stored in the saved conf file. But if you add them manually they will be considered.


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
  monit/conf-available/password-expiry
  systemd/system/disable-offload.service
usr/
  local/bin/check-password-expiry.sh
```

Files containing `%%PLACEHOLDER%%` variables are copied to the target path after all services are installed and substituted with `sed`. Files without placeholders are copied as-is.

### Postfix (`etc/postfix/main.cf`)

| Placeholder | Value                                                     |
|---|-----------------------------------------------------------|
| `%%POSTFIX_RELAY_HOST%%` | SMTP relay hostname or ip                                 |
| `%%POSTFIX_RELAY_PORT%%` | SMTP relay port, e.g. 587                                 |
| `%%POSTFIX_RELAY_USERNAME%%` | Username for SMTP host                                    |
| `%%POSTFIX_RELAY_PASSWORD%%` | Password for POSTFIX_RELAY_USERNAME at POSTFIX_RELAY_HOST |
| `%%POSTFIX_DOMAIN%%` | Mail domain (also written to `/etc/mailname`)             |
| `%%POSTFIX_FROM_ADDRESS%%` | From address                                      |
| `%%POSTFIX_ROOT_ALIAS%%` | Forward local root mail to this address                   |

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

### Password Expiry Check (`usr/local/bin/check-password-expiry.sh`)

| Placeholder | Value |
|---|---|
| `%%USER_SUDO_USER_USERNAME%%` | Sudo username — substituted at install time |

Called by Monit to alert when the sudo user's password is approaching expiry. Alerts at 30, 20, 10, and 5 days remaining. Exits 0 (OK) if the password is set to never expire.

### Forgejo (`etc/forgejo/app.ini`)

| Placeholder                  | Value                                               |
|------------------------------|-----------------------------------------------------|
| `%%FORGEJO_DOMAIN%%`         | Domain name or IP (defaults to server's primary IP) |
| `%%FORGEJO_PORT%%`           | HTTP port (3000, or 3030 if Grafana also installed) |
| `%%FORGEJO_MAILER_ENABLED%%` | `true` or `false`                                   |
| `%%FORGEJO_SMTP_ADDR%%`      | SMTP host (empty if via Postfix)                    |
| `%%FORGEJO_SMTP_PORT%%`      | SMTP port (empty if via Postfix)                    |
| `%%FORGEJO_SMTP_FROM%%`      | From address                                        |
| `%%FORGEJO_SMTP_USER%%`      | SMTP username (empty if via Postfix)                |
| `%%FORGEJO_SMTP_PASSWORD%%`  | SMTP password (empty if via Postfix)                |
| `%%FORGEJO_DB_TYPE%%`        | sqlite3/mysql/postgres. Default is sqlite3          |
| `%%FORGEJO_DB_NAME%%`        | Database name (empty for sqlite3)                   |
| `%%FORGEJO_DB_USER%%`        | Database username (empty for sqlite3)               |
| `%%FORGEJO_DB_PASSWORD%%`    | Database password (empty for sqlite3)               |
| `%%FORGEJO_DB_HOST%%`        | Database host (empty for sqlite3)                   |

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

Run it any time (as root) to get a colour-coded status report covering:

- SSH configuration
- Swap and disk usage
- Memory usage
- TCP transmit offloading status
- Failed systemd units
- Recent failed SSH logins
- Pending package updates
- Service status for all installed services (including whether the Coraza module still matches nginx, and its mode)
- AppArmor profile status per service
- Recent AppArmor denials
- Port usage with UFW allow/block status
- **Smoke tests** — HTTP connectivity checks for Nginx, Grafana, Forgejo, Monit, and Webmin; database connection tests for MySQL/MariaDB (via a passwordless `healthcheck` user), PostgreSQL, and Valkey; and a Mosquitto pub/sub test

```bash
sudo ~/ubuntu_health_check.sh
```

---

## Notes

- **CIS Level 1 hardening:** applies a broad set of CIS benchmark controls in a single optional step (`CONFIGURE_CIS_HARDENING`). Controls are applied idempotently — safe to re-run. File integrity monitoring uses AIDE unless Wazuh is installed or selected, in which case Wazuh FIM is used instead (real-time via inotify, feeding into the Wazuh dashboard). A Monit check for sudo user password expiry is added when both Monit and a sudo user are configured — alerts are sent at 30, 20, 10, and 5 days remaining. Postfix is set to `inet_interfaces = loopback-only` regardless of the value in `main.cf` to satisfy the CIS "Disable Postfix Network Listening" control.
- **MySQL / MariaDB health check user:** a passwordless `healthcheck@localhost` user with SELECT-only access is created during installation. The health check script uses this user for connection tests — no root credentials are stored anywhere in the health check script.
- **curl and IPv6:** on Ubuntu 26.04, curl prefers IPv6 when connecting to `localhost`. The health check smoke tests use `curl -4` to force IPv4, ensuring consistent behaviour regardless of how `localhost` resolves on the system.
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

## CIS Level 1 Hardening

Enable with `CONFIGURE_CIS_HARDENING=y`. All controls are applied idempotently — safe to re-run.

### What is applied

| Area | Control |
|---|---|
| Packages | Removes `ftp`, `telnet`, `tnftp` |
| PAM passwords | `pam_pwquality`: min 14 chars, 3 character classes, max 5 consecutive identical chars |
| PAM history | `pam_pwhistory`: remembers last 5 passwords |
| PAM lockout | `pam_faillock`: locks account after 5 failed attempts, unlocks after 15 minutes |
| Password ageing | Max 365 days, min 1 day, warn at 14 days — applied to all non-system accounts |
| Inactivity lock | Account locked 30 days after password expiry |
| Umask | `027` set in `login.defs`, `/etc/profile`, `/etc/bash.bashrc` |
| su restriction | `pam_wheel` restricts `su` to members of the `wheel` group |
| System accounts | All system accounts (UID < 1000) set to `/usr/sbin/nologin`, except `root` and service accounts that legitimately need a shell (e.g. `forgejo`) |
| Cron/at | Directories set to `700`, `crontab` to `600`. `/etc/cron.allow` and `/etc/at.allow` restrict scheduling to `root` and the sudo user |
| SSH | `LogLevel INFO`, warning banner, no host-based auth, no user environment, `ClientAliveInterval 300`. CIS cipher suite, MACs, and key exchange algorithms enforced |
| Sudo logging | `Defaults logfile="/var/log/sudo.log"` (skipped on Ubuntu 26.04 which uses `sudo-rs` and logs to journald) |
| Core dumps | Disabled via PAM limits, sysctl (`fs.suid_dumpable=0`), and systemd coredump config |
| sysctl | ASLR, TCP SYN cookies, martian packet logging, ICMP redirect hardening, IPv6 RA disabled |
| Kernel modules | `cramfs`, `freevxfs`, `hfs`, `hfsplus`, `jffs2`, `udf`, `usb-storage` blacklisted |
| /dev/shm | Mounted with `nodev,nosuid,noexec` |
| Journald | Forwarded to rsyslog |
| NTP | Configured via `systemd-timesyncd` using Ubuntu pool servers |
| Session timeout | `TMOUT=900` (15 minutes) set readonly in `/etc/profile.d/cis-timeout.conf` |
| File integrity | AIDE installed and initialised unless Wazuh is present (Wazuh FIM used instead) |
| Postfix | `inet_interfaces = loopback-only` if Postfix is installed |
| Password expiry alert | Monit check alerts at 30, 20, 10, and 5 days remaining (requires Monit and a sudo user) |
| Apport | Disabled and masked |

### CIS exceptions

Two intentional deviations from strict CIS Level 1:

- **Password complexity:** CIS requires all 4 character classes (`dcredit`, `ucredit`, `ocredit`, `lcredit = -1`). This script uses `minclass = 3` instead, in line with NIST SP 800-63B guidance that length matters more than forced complexity. The 14-character minimum is preserved.
- **`maxrepeat`:** set to `5` rather than the CIS default of `3`, to accommodate passphrase-style passwords with separator characters (e.g. `correct-horse-battery-staple`) which would otherwise be rejected due to repeated hyphens.

### PAM recovery

If PAM is misconfigured and authentication breaks, the fastest recovery is:

```bash
# From a root console (cloud provider web console / IPMI)
pam-auth-update --force
faillock --user YOUR_USERNAME --reset
passwd YOUR_USERNAME
```

See `howto/howto-pam-recovery.md` for full recovery procedures including GRUB single-user mode and chroot from a rescue image.

---

## Security Auditing with Lynis

Lynis is installed from the [CISOfy repository](https://packages.cisofy.com) to ensure the current release is used. The Ubuntu universe package lags significantly behind.

### Running an audit

```bash
# Full system audit
sudo lynis audit system

# Show the hardening index score
sudo lynis audit system | grep "Hardening index"

# Audit only a specific category
sudo lynis audit system --tests-category authentication
sudo lynis audit system --tests-category networking
sudo lynis audit system --tests-category storage
```

### Reports and logs

| File | Contents |
|---|---|
| `/var/log/lynis.log` | Full detailed audit log |
| `/var/log/lynis-report.dat` | Machine-readable report (key=value format) |

### Interpreting results

Lynis produces **Suggestions** and **Warnings**:

- **Warnings** (marked `[WARNING]`) are higher priority — address these first.
- **Suggestions** (marked `[suggestion]`) are improvements but not necessarily failures.
- The **Hardening Index** (0–100) gives an overall score. A freshly CIS-hardened server typically scores 75–85. Getting above 90 requires additional manual controls beyond what this script applies.

### Common findings after CIS hardening

Some Lynis findings are intentional and can be acknowledged:

| Finding | Reason acceptable |
|---|---|
| `AUTH-9282` — password complexity | Intentional exception — `minclass=3` chosen over strict 4-class requirement |
| `KRNL-5820` — kernel update available | Ubuntu kernel updates are handled by `unattended-upgrades` |
| `FIRE-4513` — no outbound firewall rules | UFW outbound is open by design; restrict further if your threat model requires it |
| `MAIL-8818` — Postfix listening | Only on loopback (`inet_interfaces = loopback-only`) — this is correct |

### Keeping Lynis current

Lynis is installed via direct `.deb` download rather than an apt repo. Use the upgrade script:

```bash
sudo ./utils/upgrade_lynis.sh
lynis show version
```

---

## Upgrading

### Automatic updates via apt

The following are installed from apt repositories and update automatically with `sudo apt-get update && sudo apt-get upgrade` (or via `unattended-upgrades` if enabled):

| Package | Repository |
|---|---|
| Ubuntu system packages (nginx, postfix, mysql, mariadb, postgresql, valkey, suricata, fail2ban, auditd, monit, etc.) | Ubuntu / Ubuntu PPA |
| PostgreSQL | [apt.postgresql.org](https://apt.postgresql.org) |
| Grafana | [apt.grafana.com](https://apt.grafana.com) |
| Webmin | Webmin apt repo (configured by `webmin-setup-repo.sh`) |
| Python 3.14 | deadsnakes PPA (`ppa:deadsnakes/ppa`) |

### Manual updates

The following require manual upgrade steps. Check for new releases and follow the instructions below.

#### Wazuh Agent

The Wazuh Agent version must never exceed the manager version, or the agent may fail to connect or drop events silently.
Wazuh Agent is installed from the Wazuh apt repo but is **pinned with `apt-mark hold`** to prevent it auto-upgrading.

**Always upgrade the Wazuh Manager first, then upgrade agents to match.**

There is no way to query the manager version from the agent host — check it on the manager server before running the upgrade:

```bash
# On the manager server
/var/ossec/bin/wazuh-control info | grep VERSION
```

Then run the upgrade script on each agent:

```bash
# Prompts for the target version
sudo ./utils/upgrade_wazuh_agent.sh

# Or pass the version directly
sudo ./utils/upgrade_wazuh_agent.sh 4.14.7
```

The script unholds the package, installs the specified version, re-pins with `apt-mark hold`, restarts the service, and verifies the result.

#### Lynis

Lynis is installed by downloading the `.deb` directly from CISOfy rather than adding their apt repo. The CISOfy repo requires a GPG key that can fail to download or validate, which would cause every subsequent `apt-get update` call in the script — including those triggered internally by Grafana, PostgreSQL, and other package installs — to fail with a signature error and abort the run. Downloading the `.deb` directly avoids registering anything in `sources.list.d` and keeps Lynis completely isolated from the rest of the apt stack. Any leftover CISOfy repo files from earlier runs are removed at the start of section 8 before `apt-get update` runs.

```bash
# Upgrade to latest
sudo ./utils/upgrade_lynis.sh

# Or pin to a specific version
sudo ./utils/upgrade_lynis.sh 3.1.1
```

The script fetches the latest version from the CISOfy GitHub API, compares it to the installed version, and skips if already current. If the CISOfy download fails, it falls back to `apt-get install lynis` from Ubuntu universe and tells you whether the universe version matches the target or is older.

#### Forgejo

Forgejo is downloaded directly from [Codeberg](https://codeberg.org/forgejo/forgejo/releases). The script fetches the latest release at install time and falls back to `FORGEJO_FALLBACK_VERSION` if the API is unreachable.

Use the upgrade script in `utils/`:

```bash
# Upgrade to latest
sudo ./utils/upgrade_forgejo.sh

# Or pin to a specific version
sudo ./utils/upgrade_forgejo.sh 16.0.4
```

The script fetches the latest release from the Codeberg API, backs up the database (sqlite3, MySQL, or PostgreSQL — detected automatically from `/etc/forgejo/app.ini`), stops the service, replaces the binary, and restarts. Backups are written to `/var/backups/forgejo/`.

#### PyPy 3.11

PyPy is downloaded from [downloads.python.org/pypy](https://downloads.python.org/pypy) and installed to `/opt/`. The symlinks `/usr/local/bin/pypy3`, `pypy3.11`, and `pypy` point to the active version. Old versions in `/opt/` are left in place and must be removed manually.

```bash
# Upgrade to latest
sudo ./utils/upgrade_pypy.sh

# Or pin to a specific version
sudo ./utils/upgrade_pypy.sh pypy3.11-v7.3.23
```

#### Coraza WAF for nginx

`utils/install_coraza_nginx.sh` compiles [Coraza](https://github.com/corazawaf/coraza-nginx) (libcoraza + the coraza-nginx connector) as a dynamic module for the nginx package installed by this script, and installs the [OWASP Core Rule Set](https://coreruleset.org/) into `/etc/nginx/coraza/`. No Docker. It can also be run by the provisioning script: answer `y` to the Coraza prompt (or set `INSTALL_CORAZA=y` in the config file, which requires `INSTALL_NGINX=y`). This only builds and installs the module; **it does not activate the WAF**, so follow the steps below afterwards. It needs Go 1.25 or later to build; if the system Go is older it downloads the official (checksum-verified) release into a temporary directory and removes it afterwards.

```bash
sudo ./utils/install_coraza_nginx.sh          # install (or rebuild)
sudo ./utils/install_coraza_nginx.sh check    # does the module still match the installed nginx?
sudo ./utils/install_coraza_nginx.sh enforce  # start blocking (default after install is detect-only)
sudo ./utils/install_coraza_nginx.sh detect   # back to log-only
```

The module is loaded but inactive until a site enables it inside its `server { }` block:

```nginx
coraza on;
coraza_rules_file /etc/nginx/coraza/coraza-nginx.conf;
```

Recommended rollout: leave it in detect-only mode for a couple of weeks, review `/var/log/nginx/coraza_audit.json` (also monitored by the Wazuh agent), add exclusions for false positives to `/etc/nginx/coraza/before-crs.conf`, then run `enforce`. Files under `/etc/nginx/coraza/` other than `crs/rules/` are never overwritten on re-run. Use `coraza off;` in locations that serve static files.

**Upgrades:** a dynamic module only loads into the exact nginx version it was built for. An apt hook (`/etc/apt/apt.conf.d/99-coraza-nginx`) notices when nginx changes upstream version, or when nginx reports the module as "not binary compatible", and rebuilds the module a couple of minutes later (log: `/var/log/coraza-nginx-build.log`). If the rebuild fails, the running nginx keeps working but the next restart will fail, so include `install_coraza_nginx.sh check` in your monitoring. To update libcoraza, coraza-nginx or the CRS, change the `*_TAG` variables (or pass them as environment variables) and re-run the script.

#### Modulejail

Modulejail is a one-shot script that blacklists unused kernel modules by writing `/etc/modprobe.d/modulejail-blacklist.conf`. It does not run as a service. Re-run it after adding new services to pick up any newly loaded modules. A reboot is required for blacklist changes to take effect.

```bash
# Re-run at latest version
sudo ./utils/upgrade_modulejail.sh

# Or use a specific version
sudo ./utils/upgrade_modulejail.sh 1.6.1
```

The script preserves the whitelist at `/etc/modulejail/whitelist.conf` and backs up the existing blacklist before regenerating it.

---

## Limitations

- Does not configure network interfaces or disk partitions beyond LVM resizing and swap creation.
- Does not back up or restore MySQL/PostgreSQL databases — only service configuration files.
- Requires internet access at runtime to download packages and (for Forgejo and PyPy) fetch the latest release version.
- `/etc/security/limits.d/` changes only apply to PAM-authenticated sessions. Services managed by systemd use their own `LimitNOFILE` directives in their unit files or overrides.
- All blocked services are only accessible via localhost or through Nginx as a reverse proxy (not configured).

---

## License

MIT — use freely, modify as needed.
