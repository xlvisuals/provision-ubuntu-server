# Howto: Tune System

## Background

The tune system step applies a set of server optimisations:

- **APT timers** — schedules unattended-upgrades at specified UTC hours
- **needrestart** — set to automatic mode so kernel upgrades never prompt interactively
- **APT timeouts** — 5 second timeout with no retries so apt fails fast on unavailable mirrors
- **File limits** — raises `nofile` and `nproc` in `limits.d`
- **Kernel tuning** — `sysctl` hardening (swap tuning, ICMP redirect blocking, IP spoofing prevention, kernel pointer/dmesg restrictions)
- **Shared memory** — `/run/shm` mounted `nosuid,nodev,noexec`
- **Ubuntu Pro** — if not attached, disables background Pro services to reduce noise
- **TCP TX offloading** — optionally disables transmit offloading on the primary interface

---

## Conf file

```bash
cat > /tmp/tune.conf << 'EOF'
INSTALL_DEFAULT=n
USER_CREATE_SUDO_USER=n
USER_USE_CURRENT_USERNAME=y
TUNE_SYSTEM=y
AUTO_UPDATE_DAILY_HOUR=9
AUTO_UPGRADE_DAILY_HOUR=10
DISABLE_TX_OFFLOAD=n
CONFIGURE_APPARMOR=y
APPARMOR_ENABLE=y
APPARMOR_ENFORCE=y
EOF
```

Run:

```bash
sudo bash ubuntu_provision.sh /tmp/tune.conf
```

---

## Verify

**APT timers:**

```bash
systemctl cat apt-daily.timer | grep OnCalendar
systemctl cat apt-daily-upgrade.timer | grep OnCalendar
```

**needrestart mode:**

```bash
grep "nrconf{restart}" /etc/needrestart/needrestart.conf | grep -v "^#"
# Should show: $nrconf{restart} = 'a';
```

**APT timeout:**

```bash
cat /etc/apt/apt.conf.d/99timeout
```

**File limits:**

```bash
cat /etc/security/limits.d/*.conf
ulimit -n    # open files (run as your user, not root)
ulimit -u    # processes
```

**Kernel tuning:**

```bash
sudo sysctl vm.swappiness
sudo sysctl kernel.kptr_restrict
sudo sysctl kernel.dmesg_restrict
sudo sysctl net.ipv4.conf.all.accept_redirects
```

**Shared memory:**

```bash
mount | grep shm
```

**TCP TX offloading** (if enabled):

```bash
sudo systemctl status disable-offload.service
sudo ethtool -k $(ip route show default | awk '{print $5}' | head -1) | grep tx-checksumming
# Should show: tx-checksumming: off
```

**AppArmor:**

```bash
sudo aa-status | grep -E "profiles are in enforce|profiles are in complain"
```

---

## Notes

- File limit changes in `limits.d` only apply to PAM-authenticated sessions.
  Services managed by systemd use their own `LimitNOFILE` in their unit files.
- Kernel tuning changes (`sysctl`) take effect immediately and persist via
  `/etc/sysctl.d/99-xlvisuals.conf`.
- APT timer changes require a reboot or `systemctl daemon-reload` followed by
  `systemctl restart apt-daily.timer apt-daily-upgrade.timer` to take effect.
- TCP TX offload changes take effect immediately but are applied via a systemd
  oneshot service so they persist across reboots.
