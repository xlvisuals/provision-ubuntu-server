# Howto: (Re)install Monit

## Background

Monit monitors services and sends alerts when something goes wrong. It watches
process state, port availability, file checksums, and resource usage. The web
UI is available on port 2812 (localhost only — access via SSH port forward).

Mail is routed through Postfix if installed, otherwise via a direct SMTP
connection.

---

## Conf file

A .conf file is optional. If none is provided, the script prompts for each option. \
If a .conf file is provided but options are missing, the script prompts for these options.

### With Postfix (recommended)

```bash
cat > /tmp/monit.conf << 'EOF'
INSTALL_DEFAULT=n
USER_CREATE_SUDO_USER=n
USER_USE_CURRENT_USERNAME=y
INSTALL_MONIT=y
MONIT_USE_POSTFIX=y
MONIT_ALERT_SENDER=monit@example.com
MONIT_ALERT_RECIPIENT=admin@example.com
MONIT_ADMIN_USERNAME=admin
# Passwords will be prompted:
# MONIT_ADMIN_PASSWORD=
EOF
```

### Without Postfix (direct SMTP)

```bash
cat > /tmp/monit.conf << 'EOF'
INSTALL_DEFAULT=n
USER_CREATE_SUDO_USER=n
USER_USE_CURRENT_USERNAME=y
INSTALL_MONIT=y
MONIT_USE_POSTFIX=n
MONIT_MAILSERVER_HOST=smtp.example.com
MONIT_MAILSERVER_PORT=587
MONIT_MAILSERVER_USERNAME=monit@example.com
MONIT_ALERT_SENDER=monit@example.com
MONIT_ALERT_RECIPIENT=admin@example.com
MONIT_ADMIN_USERNAME=admin
# Passwords will be prompted:
# MONIT_MAILSERVER_PASSWORD=
# MONIT_ADMIN_PASSWORD=
EOF
```

Run:

```bash
sudo bash ubuntu_provision.sh /tmp/monit.conf
```

You will be prompted for the admin password (and mail password if not using Postfix).

---

## Access the web UI

Monit's web UI is only accessible on localhost. Use an SSH port forward:

```bash
ssh -L 2812:localhost:2812 user@yourserver
```

Then open: http://localhost:2812

---

## Verify

**Check service status:**

```bash
sudo systemctl status monit
sudo monit status
```

**Test the config:**

```bash
sudo monit -t
```

**Send a test alert:**

```bash
sudo monit reload
sudo monit summary
```

**Check which services are monitored:**

```bash
ls /etc/monit/conf-enabled/
```

**Check the Monit log:**

```bash
sudo tail -20 /var/log/monit.log
```

---

## Troubleshoot

**Config parse error:**
```bash
sudo monit -t
# Shows exact line and error
```

**Service showing as failed in Monit but running in systemd:**
Monit may be using the wrong PID file path. Check the conf-available file for
that service:
```bash
cat /etc/monit/conf-available/<service>
sudo monit reload
```

**Alert emails not arriving:**
```bash
sudo tail -20 /var/log/mail.log | grep monit
```

**Manually trigger a check:**
```bash
sudo monit check <service>
```

**Restart a service via Monit:**
```bash
sudo monit restart <service>
```
