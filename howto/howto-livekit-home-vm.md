# Howto: Test LiveKit on a home VM

## Background

`ubuntu_provision.sh` expects a LiveKit server with public DNS names and Let's Encrypt certificates (see
[howto-livekit.md](howto-livekit.md)). A VM at home usually has neither, so this guide uses names that only exist on
your network and certificates you create yourself.

The script reuses any certificate it finds in `/etc/letsencrypt/live/<domain>/` (`fullchain.pem` and `privkey.pem`)
and then skips Let's Encrypt. Copy the certificates there before running the script.

Two ways to test:

| | LAN only (option 1) | From outside (option 2) |
|---|---|---|
| Names | `livekit.home.arpa`, `turn.home.arpa` | Real subdomains, e.g. `livekit-test.example.org` |
| Certificates | mkcert, copied in before the run | Let's Encrypt (script) |
| Router changes | None | Port forwarding |
| Clients | Devices on your network that trust the mkcert CA | Anyone |

The examples use `192.168.1.50` for the VM. Replace it with yours (`hostname -I` on the VM).

---

## Option 1: LAN only

### 1. Names

`home.arpa` is reserved for home networks, so it can't clash with a real domain.

On the VM **and** on every client that will join a call, add to `/etc/hosts`
(Windows: `C:\Windows\System32\drivers\etc\hosts`):

```
192.168.1.50  livekit.home.arpa turn.home.arpa
```

Or add both names once in your router's or Pi-hole's local DNS instead.

The entry on the VM also makes the script's DNS check pass.

### 2. Install mkcert

[mkcert](https://github.com/FiloSottile/mkcert) creates a local certificate authority (CA) and certificates signed by
it. Install it on the machine where you create the certificates, and on any client that should trust them.

**macOS** (with [Homebrew](https://brew.sh)):

```bash
brew install mkcert
brew install nss        # only for Firefox, which has its own certificate store
```

Without Homebrew: `sudo port install mkcert` (MacPorts), or download `mkcert-v*-darwin-arm64` (Apple Silicon) or
`mkcert-v*-darwin-amd64` (Intel; `uname -m` shows which) from the
[releases page](https://github.com/FiloSottile/mkcert/releases), then:

```bash
chmod +x ~/Downloads/mkcert-v*-darwin-*
xattr -d com.apple.quarantine ~/Downloads/mkcert-v*-darwin-*   # otherwise macOS blocks the downloaded binary
sudo mv ~/Downloads/mkcert-v*-darwin-* /usr/local/bin/mkcert
```

**Windows** (PowerShell as administrator), with [Chocolatey](https://chocolatey.org) or [Scoop](https://scoop.sh):

```powershell
choco install mkcert
# or
scoop bucket add extras
scoop install mkcert
```

Without a package manager: download `mkcert-v*-windows-amd64.exe` from the
[releases page](https://github.com/FiloSottile/mkcert/releases), rename it to `mkcert.exe` and put it in a folder
on your `PATH`.

**Ubuntu:**

```bash
sudo apt install mkcert libnss3-tools    # libnss3-tools: lets mkcert add its CA to Firefox and Chrome
```

Then, on each machine:

```bash
mkcert -install    # trust mkcert's local CA (asks for your password or an admin prompt)
mkcert -CAROOT     # shows the folder with rootCA.pem
```

**Clients without mkcert** can trust the CA by importing `rootCA.pem` (copy it from the `mkcert -CAROOT` folder;
never copy `rootCA-key.pem`, which can sign certificates for any name):

| OS | Command |
|---|---|
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain rootCA.pem` |
| Windows | `certutil -addstore -f ROOT rootCA.pem` (as administrator) |
| Ubuntu | `sudo cp rootCA.pem /usr/local/share/ca-certificates/mkcert-rootCA.crt && sudo update-ca-certificates` |

Firefox on Ubuntu uses its own store: import `rootCA.pem` under Settings > Privacy & Security > Certificates.
Phones need the CA installed as a user certificate, which varies by OS.

### 3. Certificates

On your desktop, create one certificate per name:

```bash
mkdir -p lk-certs/livekit lk-certs/turn
mkcert -cert-file lk-certs/livekit/fullchain.pem -key-file lk-certs/livekit/privkey.pem livekit.home.arpa
mkcert -cert-file lk-certs/turn/fullchain.pem    -key-file lk-certs/turn/privkey.pem    turn.home.arpa

scp -r lk-certs user@192.168.1.50:/tmp/
```

On the VM:

```bash
for n in livekit turn; do
    sudo install -d -m 755 "/etc/letsencrypt/live/$n.home.arpa"
    sudo install -m 644 "/tmp/lk-certs/$n/fullchain.pem" "/etc/letsencrypt/live/$n.home.arpa/fullchain.pem"
    sudo install -m 600 "/tmp/lk-certs/$n/privkey.pem"   "/etc/letsencrypt/live/$n.home.arpa/privkey.pem"
done
rm -rf /tmp/lk-certs
```

Every client that joins a call must trust mkcert's CA (step 2).

### 4. Conf file

```bash
cat > /tmp/livekit-vm.conf << 'EOF'
INSTALL_DEFAULT=n
USER_CREATE_SUDO_USER=n
USER_USE_CURRENT_USERNAME=y
INSTALL_UFW=y
INSTALL_NGINX=y
INSTALL_LIVEKIT=y
LIVEKIT_DOMAIN=livekit.home.arpa
LIVEKIT_TURN_TLS=y
LIVEKIT_TURN_DOMAIN=turn.home.arpa
# Any valid address: not used while the certificates exist
LIVEKIT_LE_EMAIL=you@example.com
LIVEKIT_LE_STAGING=n
# Needed for a LAN address; without it the script refuses a private IP
LIVEKIT_ALLOW_PRIVATE_NODE_IP=y
LIVEKIT_NODE_IP=192.168.1.50
LIVEKIT_RTC_PORT_START=50000
LIVEKIT_RTC_PORT_END=60000
LIVEKIT_ROOM_MAX_PARTICIPANTS=10
# Or your dev app's https URL, e.g. https://cpd.home.arpa/api/v1/livekit/webhook
LIVEKIT_WEBHOOK_URL=none
# Or your dev app's LAN IP if it calls the server API
LIVEKIT_API_ALLOW_FROM=none
EOF
sudo bash ubuntu_provision.sh /tmp/livekit-vm.conf
```

The run should report `A certificate for livekit.home.arpa already exists - reusing it.` for both names. If it
tries to contact Let's Encrypt instead, a file is missing or in the wrong folder.

### 5. Connect your dev app

```bash
sudo cat /etc/livekit/keys.yaml    # "<API key>: <secret>"
```

- `LIVEKIT_URL=wss://livekit.home.arpa`
- `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` from the file above

The machine running the dev app needs the hosts entry and the mkcert CA (step 2) too.

---

## Option 2: From outside

Use this to test like production, e.g. from a phone on mobile data.

1. Create DNS A records for two real subdomains (e.g. `livekit-test.example.org`, `turn-test.example.org`)
   pointing to your home public IP.
2. Forward these ports from your router to the VM:

   | Port | Use |
   |---|---|
   | 80/tcp | Let's Encrypt challenges |
   | 443/tcp | Signalling and TURN/TLS |
   | 7881/tcp | ICE over TCP |
   | 50000-60000/udp | Media |
   | 3478/udp | TURN/UDP |

3. Run the script with:
   - `LIVEKIT_DOMAIN` and `LIVEKIT_TURN_DOMAIN` set to the real subdomains
   - `LIVEKIT_NODE_IP` set to your home **public** IP (no `LIVEKIT_ALLOW_PRIVATE_NODE_IP` needed)
   - `LIVEKIT_LE_STAGING=y` for the first run
4. The DNS check warns because the public IP isn't on the VM. Answer `y` to "Request the certificates anyway?",
   or set `LIVEKIT_DNS_OVERRIDE=y` in the .conf.
5. Once staging works, delete the staging certificates and run again with `LIVEKIT_LE_STAGING=n`:

   ```bash
   sudo certbot delete --cert-name livekit-test.example.org
   sudo certbot delete --cert-name turn-test.example.org
   ```

Devices on your LAN reach the VM through the public IP, which only works if the router supports NAT loopback
(hairpinning). If calls fail from inside but work from mobile data, that's the likely cause.

Close the port forwards when you're done testing.

---

## Checks

```bash
systemctl status livekit
curl -s http://127.0.0.1:7880/                                                    # OK
curl -s -o /dev/null -w '%{http_code}\n' https://livekit.home.arpa/              # 200 (from a client with the CA)
openssl s_client -connect turn.home.arpa:443 -servername turn.home.arpa </dev/null | head -5
sudo bash ~/ubuntu_health_check.sh    # written to the sudo user's home by the script
```

Test a call with two browsers on different machines. To check TURN/TLS, block outgoing UDP on one of them (e.g. in
its firewall) and join again: the call should still connect, over 443.

---

## Notes

- **Certificate validity:** mkcert certificates last about two years and are not renewed. `certbot renew` ignores
  them because they have no renewal config. The health check warns 14 days before they expire.
- **Before the production run on the same VM or image:** remove the `/etc/hosts` entries and the folders in
  `/etc/letsencrypt/live/` for the test names, or use different names. Otherwise the test certificates are reused.
- **Proxmox/VirtualBox networking:** the VM needs a bridged network adapter (its own LAN address). With NAT
  networking, clients can't reach the media ports.
- **Other https sites on the VM:** with `LIVEKIT_TURN_TLS=y`, they must listen on `127.0.0.1:8443 ssl proxy_protocol`
  (see [howto-livekit.md](howto-livekit.md)).
