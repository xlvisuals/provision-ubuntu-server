# Howto: (Re)install Postfix

## Background

Postfix is configured as a relay-only SMTP server — it accepts local mail and
forwards everything to an external SMTP provider. All services (Monit, Grafana,
Forgejo) route mail through `localhost:25` rather than connecting directly to
an external SMTP server.

---

## Conf file

```bash
cat > /tmp/postfix.conf << 'EOF'
INSTALL_DEFAULT=n
USER_CREATE_SUDO_USER=n
USER_USE_CURRENT_USERNAME=y
INSTALL_POSTFIX=y
POSTFIX_RELAY_HOST=mail.example.com
POSTFIX_RELAY_PORT=587
POSTFIX_RELAY_USERNAME=user@example.com
POSTFIX_DOMAIN=example.com
POSTFIX_FROM_ADDRESS=root@example.com
POSTFIX_ROOT_ALIAS=admin@example.com
# POSTFIX_RELAY_PASSWORD will be prompted
EOF
```

Run:

```bash
sudo bash ubuntu_provision.sh /tmp/postfix.conf
```

You will be prompted for `POSTFIX_RELAY_PASSWORD`.

---

## Verify

**Send a test email:**

```bash
echo "Test email from $(hostname)" | mail -s "Postfix Test" admin@example.com
```

**Check mail log:**

```bash
sudo tail -20 /var/log/mail.log
```

A successful relay looks like:

```
postfix/smtp[...]: status=sent (250 2.0.0 Ok: queued)
```

**Check service status:**

```bash
sudo systemctl status postfix
```

**Check the relay is configured correctly:**

```bash
postconf relayhost
postconf myorigin
postconf inet_interfaces
```

---

## Troubleshoot

**Authentication failure:**
```bash
sudo tail -20 /var/log/mail.log | grep "SASL\|authentication"
```

**Check sasl_passwd is hashed (plaintext file should not exist):**
```bash
ls -la /etc/postfix/sasl_passwd*
# Should show only sasl_passwd.db, not sasl_passwd
```

**Check sender rewriting is active:**
```bash
cat /etc/postfix/sender_canonical_maps
postconf sender_canonical_maps
```

**Reload after config changes:**
```bash
sudo postfix reload
```
