# Ubuntu 24.04 + 26.04 Server Provisioning Script

An interactive Bash provisioning script for **Ubuntu 24.04 LTS** and **Ubuntu 26.04 LTS** Server to quickly provision a secure webserver. 
The script is re-entrant, but best run on a fresh **minimized** or **standard** install. 
Every component is optional — you choose what gets installed and configured at runtime via interactive prompts.

---

## Requirements

| Requirement | Detail |
|---|---|
| OS | Ubuntu 24.04 LTS Server or Ubuntu 26.04 LTS Server (minimized or standard) |
| Disk space | 8 GB (minimized install) · 12 GB (standard install) |
| Privileges | Must be run as root (`sudo`) |
| Network | Active internet connection |

---

## Quick Start

```bash
sudo bash ubuntu_provision.sh
```

A timestamped log is written automatically to `/var/log/ubuntu_provision_<date>.log`.

> **After the script completes:** test SSH login in a *new* terminal window before closing the current session, then reboot to apply all changes.

---

## What It Does

The script walks you through each step with a `y/n` prompt, so nothing is changed without your confirmation.

### System Configuration

| Step | Description |
|---|---|
| Backup | Original configs (`/etc/ssh`, `/etc/apt`, `sysctl.conf`, `fstab`, `limits.conf`) are backed up to `/root/original_config_backup_<date>/` |
| Timezone | Set to UTC |
| LVM | Optionally resize LVM to use 100% of the volume group |
| Swap | Creates a configurable swap file (default 2 GB) if none exists |
| Uninstall | Removes unneeded packages (`modemmanager`, `snapd`, `bluetooth`, `apport`, etc.) |
| Updates | Full system upgrade via `apt-get full-upgrade` |
| UFW Firewall | Default deny inbound, allow outbound; opens ports 22, 80, 443 as appropriate |
| SSH Hardening | Key-only authentication, no root login, restricted `AllowUsers`, `MaxAuthTries 3` |
| Sudo | 60-minute `timestamp_timeout`; NOPASSWD for `apt-get`, `systemctl`, `reboot`, and the health check script |
| Update Timers | Unattended-upgrades scheduled to 10:00 and 22:00 daily |
| File Limits | `nofile` raised to 65,536 for all users including root |
| Kernel Tuning | `sysctl` hardening — swap tuning, ICMP redirect blocking, IP spoofing prevention, kernel pointer/dmesg restrictions |
| Shared Memory | `/run/shm` mounted `nosuid,nodev,noexec` |
| Fonts | Liberation, FreeFonts, and Microsoft core fonts (with EULA pre-acceptance) |
| User | Creates a new sudo user or configures an existing one; sets up SSH key access |

### Software Installed (all optional)

**Web Stack**

| Package | Default Port |
|---|---|
| Nginx | 80, 443 |
| MySQL Server | 3306 |
| PostgreSQL 18 | 5432 |
| Valkey (Redis-compatible cache) | 6379 |
| Mosquitto MQTT Broker | 1883 |

**Management & Monitoring**

| Package | Default Port |
|---|---|
| Webmin | 10000 | Installed via official `webmin-setup-repo.sh` script |
| Monit | 2812 |
| Grafana | 3000 |
| Forgejo (self-hosted Git) | 3000 (3030 if Grafana is also installed) |

**Runtimes**

| Package | Notes |
|---|---|
| Python 3.14 | Pre-installed with Ubuntu 26.04 |
| PyPy 3.11 | High-performance Python runtime; latest version fetched dynamically at install time |

**Security**

| Package | Notes |
|---|---|
| Fail2Ban | Bans IPs after repeated failed SSH attempts |
| auditd | Kernel-level audit logging |
| Suricata IDS | Network intrusion detection; `community-id` enabled; rules updated via `suricata-update` |
| Wazuh Agent | SIEM agent; requires a Wazuh Manager IP/hostname; integrates Suricata and auditd logs |
| UFW IP Blocklist | Daily cron job pulls and applies an IP blocklist via `ipsum` |

**Tools**

`vim` · `nano` · `ne` · `micro` · `btop` · `ncdu` · `nmap` · `lynis` · `iftop` · `iotop` · `sysstat` · `mc` · `speedtest-cli` · `jq` · `git` · `git-lfs` · `curl` · `wget` · `weasyprint` · `imagemagick`

---

## Port Reference

| Service | Port |
|---|---|
| SSH | 22 |
| Nginx HTTP | 80 |
| Nginx HTTPS | 443 |
| MySQL | 3306 |
| PostgreSQL | 5432 |
| Valkey | 6379 |
| Mosquitto | 1883 |
| Monit | 2812 |
| Grafana | 3000 |
| Forgejo (standalone) | 3000 |
| Forgejo (with Grafana) | 3030 |
| Webmin | 10000 |

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

- **Idempotent-friendly:** the script detects already-installed services and prompts to `reinstall` rather than blindly overwriting.
- **SSH lockout prevention:** if you choose to harden SSH, the script requires a valid public key before proceeding — it will abort rather than risk locking you out.
- **Wazuh:** requires an existing Wazuh Manager. The agent is configured to forward Suricata (`eve.json`) and auditd logs to the manager automatically.
- **Forgejo & Grafana:** if both are installed, Forgejo is shifted to port 3030 to avoid a conflict.
- **PostgreSQL version** is pinned to 18 (configurable via `PG_VERSION` at the top of the script).
- **Python venvs:** `setuptools` and `wheel` are not installed at the system level. Install them per-project inside a venv: `python3.14 -m venv /path/to/venv && pip install setuptools wheel`.
- **PyPy:** installed to `/opt` and symlinked into `/usr/local/bin`. The latest PyPy 3.11 release is fetched dynamically at install time.
- **Webmin:** installed via the official `webmin-setup-repo.sh` script, which handles GPG keys and repo configuration automatically.

---

## License

MIT — use freely, modify as needed.
