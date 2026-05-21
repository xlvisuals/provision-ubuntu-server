# Howto: Reinstall and Verify the UFW IP Blocklist

## Background

The UFW IP blocklist uses `ipset` to block IPs from the
[stamparm/ipsum](https://github.com/stamparm/ipsum) project (level 3 — IPs
found in 3+ blacklists). The blocklist is updated daily via a cron job in
`/etc/cron.daily/ufw-blocklist-ipsum`.

The cron script updates the in-memory `ipset` only. The file `/etc/ipsum.4.txt`
is used by `/etc/ufw/after.init` to restore the blocklist after a reboot.
Without the save-to-file fix, the file falls out of sync and reboots restore
a stale list.

---

## Step 1 — Reinstall the blocklist on all servers

Create a small conf file to target only the blocklist:

```bash
cat > /tmp/blocklist_update.conf << 'EOF'
INSTALL_DEFAULT=n
INSTALL_IPBLOCK=y
USER_CREATE_SUDO_USER=n
USER_USE_CURRENT_USERNAME=y
EOF
```

Run the provisioning script with it:

```bash
sudo bash ubuntu_provision.sh /tmp/blocklist_update.conf
```

This reinstalls the cron script with the save-to-file fix appended.

---

## Step 2 — Trigger the cron script manually

Run the cron script immediately rather than waiting until tomorrow. This can take a minute:

```bash
sudo /etc/cron.daily/ufw-blocklist-ipsum
```

Watch progress in syslog:

```bash
sudo tail -f /var/log/syslog | grep ipsum
```

You should see:

```
2026-05-21T09:21:16.617681+00:00 hostname ufw-blocklist-ipsum: starting update of ufw-blocklist-ipsum with 9723 entries from https://raw.githubusercontent.com/stamparm/ipsum/master/levels/3.txt
2026-05-21T09:22:09.702008+00:00 hostname ufw-blocklist-ipsum: finished updating ufw-blocklist-ipsum. Old entry count: 9723 New count: 20410 of 20410
2026-05-21T09:22:09.741969+00:00 hostname ufw-blocklist-ipsum: saved 20410 entries to /etc/ipsum.4.txt for boot restoration
```

---

## Step 3 — Verify

**Check the ipset is active and has entries:**

```bash
sudo ipset list ufw-blocklist-ipsum | grep "Number of entries"
```

**Check the file was updated today:**

```bash
date -r /etc/ipsum.4.txt
```

**Check the last update time and entry count:**

```bash
sudo ipset list ufw-blocklist-ipsum | grep "Number of entries"
grep "finished updating ufw-blocklist-ipsum" /var/log/syslog | tail -1
```

**Confirm UFW is using the blocklist:**

```bash
sudo ufw status verbose | grep blocklist
```

---

## After a reboot

The blocklist is restored from `/etc/ipsum.4.txt` by `/etc/ufw/after.init`
before UFW starts. Now that the file is kept in sync after each cron run,
reboots will restore the current list rather than a stale one.

Verify after reboot with:

```bash
sudo ipset list ufw-blocklist-ipsum | grep "Number of entries"
```

---

## Troubleshooting

**ipset not active after reboot:**
```bash
sudo /etc/ufw/after.init start
sudo ufw reload
```

**Cron script fails:**
```bash
sudo grep "ufw-blocklist-ipsum" /var/log/syslog | tail -10
```

**Check which IPs are blocked:**
```bash
sudo ipset list ufw-blocklist-ipsum | head -20
```
