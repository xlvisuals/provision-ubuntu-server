# Howto: Install LiveKit (video calls)

## Background

LiveKit is a WebRTC media server (SFU) with a built-in TURN server. A web app issues short-lived access tokens
signed with the LiveKit API secret; browsers then connect to `wss://LIVEKIT_DOMAIN` for signalling and send audio and
video to this server. Nothing is recorded or stored by this setup.

Install it on a **dedicated server**. It opens a UDP port range to the internet and, with TURN/TLS on 443, nginx's
stream module takes over port 443 for the whole server.

Before running the script:

- Point DNS A records for both names to the server, e.g. `livekit.example.org` and `turn.example.org`.
- Make sure the server's public IPv4 is on the network interface, or know it if the server is behind NAT.
- Port 80 must be reachable for the Let's Encrypt challenges.

---

## Conf file

A .conf file is optional. If none is provided, the script prompts for each option. \
If a .conf file is provided but options are missing, the script prompts for these options.

### New dedicated server

```bash
cat > /tmp/livekit.conf << 'EOF'
INSTALL_DEFAULT=n
USER_CREATE_SUDO_USER=n
USER_USE_CURRENT_USERNAME=y
INSTALL_UFW=y
INSTALL_NGINX=y
INSTALL_MONIT=y
INSTALL_LIVEKIT=y
LIVEKIT_DOMAIN=livekit.example.org
LIVEKIT_TURN_TLS=y
LIVEKIT_TURN_DOMAIN=turn.example.org
LIVEKIT_LE_EMAIL=admin@example.org
LIVEKIT_LE_STAGING=n
LIVEKIT_NODE_IP=203.0.113.10
LIVEKIT_RTC_PORT_START=50000
LIVEKIT_RTC_PORT_END=60000
LIVEKIT_ROOM_MAX_PARTICIPANTS=10
LIVEKIT_WEBHOOK_URL=https://cpd.example.org/api/v1/livekit/webhook
LIVEKIT_API_ALLOW_FROM=none
EOF
sudo bash ubuntu_provision.sh /tmp/livekit.conf
```

Do a first run with `LIVEKIT_LE_STAGING=y` if you're unsure about DNS: staging certificates don't count against
Let's Encrypt's rate limits, but browsers won't trust them. Delete `/etc/letsencrypt/live/<domain>` (with
`certbot delete --cert-name <domain>`) before the real run, or the staging certificate is reused.

### Re-run (update LiveKit or change settings)

Set the same values again. The API key and secret are kept. `LIVEKIT_ROTATE_KEYS=y` creates a new pair, and the web app
must then be updated. Each run downloads the latest release (SHA-256 verified) and rewrites `/etc/livekit/livekit.yaml`
and the nginx files written for LiveKit.

---

## What you get

| Item | Where |
|---|---|
| Binary | `/usr/local/bin/livekit-server` (root, 0755) |
| Config | `/etc/livekit/livekit.yaml` (root:livekit, 0640) |
| API key + secret | `/etc/livekit/keys.yaml` (root:livekit, 0640) |
| Service | `livekit.service`, user `livekit`, no capabilities, read-only system |
| nginx site | `/etc/nginx/sites-available/livekit` |
| 443 router (TURN/TLS on) | `/etc/nginx/main.d/livekit-stream.conf`, `/etc/nginx/conf.d/livekit-realip.conf` |
| Certificates | `/etc/letsencrypt/live/<domain>/`, renewal hook `/etc/letsencrypt/renewal-hooks/deploy/50-livekit-nginx-reload` |
| Monit | `/etc/monit/conf-available/livekit` |

Ports open to the internet: 80/tcp (ACME, redirect), 443/tcp, 7881/tcp (ICE over TCP), the media range (UDP),
3478/udp (TURN). These listen on 127.0.0.1 only: 7880 (LiveKit API), 5349 (plain TURN behind nginx), 5350 (TURN TLS
terminator) and 8443 (https sites behind the router).

---

## Web app settings

```bash
sudo cat /etc/livekit/keys.yaml       # "<API key>: <secret>"
```

- `LIVEKIT_URL=wss://livekit.example.org`
- `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` from the file above. Keep the secret in the app server's environment,
  not in git.
- Webhooks arrive signed with the API key (`Authorization` header, a JWT over the body hash). Verify them with the
  LiveKit server SDK's `WebhookReceiver`, and reject anything that doesn't verify.

---

## Checks

```bash
systemctl status livekit
journalctl -u livekit -n 50
curl -s http://127.0.0.1:7880/                                   # OK
curl -s -o /dev/null -w '%{http_code}\n' https://livekit.example.org/                # 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://livekit.example.org/twirp/livekit.RoomService/ListRooms  # 403
openssl s_client -connect turn.example.org:443 -servername turn.example.org </dev/null | head -5
sudo certbot renew --dry-run
sudo systemd-analyze security livekit
```

For a call test from outside, issue a token with the LiveKit CLI (`lk token create --join --room test --identity a`)
on a machine that has the key and secret, and join from two browsers. Then test from a network that only allows
TCP 443 (e.g. block UDP on a laptop firewall) to confirm TURN/TLS works.

---

## Notes

- **Other https sites on the same server:** with TURN/TLS on, they must use `listen 127.0.0.1:8443 ssl proxy_protocol;`
  (no `[::]:443`). The script refuses to continue while a site it didn't write still listens on 443.
- **Switching TURN/TLS off** (`LIVEKIT_TURN_TLS=n` on a re-run) removes the router and moves the default and placeholder
  sites back to 443.
- **Suricata** sees the media stream (encrypted SRTP). Expect higher CPU use and some noise. Tune or exclude the media
  port range if needed.
- **Logs** go to journald: room names and participant identities appear there. Use opaque IDs in the web app and keep
  journald retention short (`SystemMaxUse=` / `MaxRetentionSec=` in `/etc/systemd/journald.conf`).
- **Monit** watches the binary's checksum (rootbin template). After an update, run `sudo monit monitor all` if Monit
  stopped monitoring LiveKit.
- **Not installed:** Egress (recording), Ingress, SIP, Redis (only needed for several LiveKit nodes).
