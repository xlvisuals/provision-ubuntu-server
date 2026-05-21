# Howto: (Re)install Suricata IDS

## Background

Suricata is a network intrusion detection system (IDS). It monitors network
traffic and logs events to `/var/log/suricata/eve.json` in JSON format.
The Wazuh agent is configured to ship this file to the Wazuh Manager for
alerting and correlation.

Key configuration applied by the provisioning script:
- `community-id: true` — enables Community ID flow hashing for correlation with other tools
- `stream.checksum-validation: no` — required on VMs and cloud servers where the
  hypervisor handles checksums before they reach Suricata. Without this, Suricata
  logs every packet as malformed, fills the disk rapidly, and misses real detections.
- Rules updated via `suricata-update` from the Emerging Threats Open ruleset

---

## Conf file

```bash
cat > /tmp/suricata.conf << 'EOF'
INSTALL_DEFAULT=n
USER_CREATE_SUDO_USER=n
USER_USE_CURRENT_USERNAME=y
INSTALL_SURICATA=y
EOF
```

Run:

```bash
sudo bash ubuntu_provision.sh /tmp/suricata.conf
```

---

## Verify

**Check service status:**

```bash
sudo systemctl status suricata
```

**Check Suricata is capturing on the right interface:**

```bash
sudo suricata --list-runmodes
sudo grep "^  - interface" /etc/suricata/suricata.yaml
```

**Check eve.json is being written:**

```bash
sudo tail -5 /var/log/suricata/eve.json | jq .
```

**Check stats:**

```bash
sudo tail -1 /var/log/suricata/stats.log
```

**Check for decode errors (should be zero or very low with checksum-validation: no):**

```bash
sudo grep "decoder.invalid" /var/log/suricata/stats.log | tail -3
```

**Update rules manually:**

```bash
sudo suricata-update
sudo systemctl restart suricata
```

**List installed rule sources:**

```bash
sudo suricata-update list-enabled-sources
```

---

## Troubleshoot

**High decode error count:**
Ensure `checksum-validation: no` is set in `/etc/suricata/suricata.yaml`
under the `stream:` block:

```bash
grep -A3 "^stream:" /etc/suricata/suricata.yaml
```

**eve.json growing too fast:**
Limit which event types are logged by editing the `eve-log` outputs section
in `/etc/suricata/suricata.yaml` and disabling noisy types like `flow` and
`anomaly`.

**Check for rule errors after update:**

```bash
sudo journalctl -u suricata --no-pager | grep -i "error\|warning" | tail -20
```
