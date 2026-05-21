# Howto: (Re)install Auditd

## Background

Auditd provides kernel-level audit logging. The provisioning script installs
the [Neo23x0 auditd ruleset](https://github.com/Neo23x0/auditd) — a
comprehensive set of rules covering file access, privilege escalation, network
connections, and many other security-relevant events.

The backlog limit is set to 8192 via `/etc/audit/rules.d/00-backlog.conf` to
prevent `audit: backlog limit exceeded` kernel messages under high load.

---

## Conf file

```bash
cat > /tmp/auditd.conf << 'EOF'
INSTALL_DEFAULT=n
USER_CREATE_SUDO_USER=n
USER_USE_CURRENT_USERNAME=y
INSTALL_AUDITD=y
EOF
```

Run:

```bash
sudo bash ubuntu_provision.sh /tmp/auditd.conf
```

---

## Verify

**Check service status:**

```bash
sudo systemctl status auditd
```

**Check loaded rules and count:**

```bash
sudo auditctl -l | wc -l
sudo auditctl -s | grep -E "enabled|backlog_limit"
```

**Check for rule loading errors (some rules may not apply to all kernels):**

```bash
sudo grep -i "error\|No such file" /var/log/syslog | grep audit | tail -10
```

**Check audit log is being written:**

```bash
sudo tail -5 /var/log/audit/audit.log
```

**Generate a test event and verify it's logged:**

```bash
sudo touch /etc/test_audit_trigger
sudo rm /etc/test_audit_trigger
sudo ausearch -k etcpasswd | tail -5
```

---

## Useful commands

**Search audit log by key:**
```bash
sudo ausearch -k <keyname>          # e.g. -k perm_mod, -k network_modifications
```

**Summary report:**
```bash
sudo aureport --summary
sudo aureport --failed
```

**Check backlog stats:**
```bash
sudo auditctl -s
```

**Reload rules after changes:**
```bash
sudo augenrules --load
```

---

## Troubleshoot

**Rules not loading (`No such file or directory`):**
Some rules reference paths or syscalls not available on this kernel/system.
These are skipped automatically and do not affect other rules. Review:

```bash
sed -n '<line>p' /etc/audit/audit.rules
```

**Backlog overflow (`audit: backlog limit exceeded`):**
```bash
sudo auditctl -s | grep backlog_limit
# If low, increase in /etc/audit/rules.d/00-backlog.conf
echo "-b 16384" | sudo tee /etc/audit/rules.d/00-backlog.conf
sudo augenrules --load
```
