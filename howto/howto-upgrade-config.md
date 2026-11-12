# Howto: Upgrade the Configuration of an Existing Server

## Background

`utils/update_server_config.sh` brings a server that was provisioned earlier up to
today's settings without re-running the whole provisioning script. It covers:

- **SSH**: the hardened drop-in `/etc/ssh/sshd_config.d/01-<user>-hardened.conf`
  (key-only login, AllowUsers, limits, optional CIS ciphers/MACs/KEX and login banner)
- **Automatic updates**: on/off, the daily `apt-get update` and `apt-get upgrade`
  hours, the timezone those hours are in, automatic reboot and its time,
  needrestart's automatic mode

Every run works the same way:

1. Shows the current values. Pressing Enter keeps a value.
2. Shows a diff of every file it would change and asks before writing.
3. Backs up each file to `/root/config-backup/update_config_<time>/`.
4. Tests the result. If a test fails, the backup is put back.

Other settings (excluded/pinned packages, the health check script, Monit checks)
are updated by re-running the provisioning script with a small conf file, see
[Other settings](#other-settings).

---

## Before you start

- Copy the current repository to the server (it does not need the rest of the
  provisioning setup).
- For SSH changes: keep your current SSH session open for the whole run, and
  have a second terminal ready to test a new login. Console access (provider web
  console, IPMI) is a good extra safety net.
- systemd must be running (the SSH rollback timer needs it). Inside a container
  without systemd the SSH section refuses to change anything.

---

## See what would change

```bash
sudo ./utils/update_server_config.sh --dry-run
```

This asks the same questions and shows the diffs, but writes nothing. Name a
section to limit the run:

```bash
sudo ./utils/update_server_config.sh ssh --dry-run
sudo ./utils/update_server_config.sh updates --dry-run
```

---

## Update SSH

```bash
sudo ./utils/update_server_config.sh ssh
```

Questions:

| Question | Default |
|---|---|
| Admin (sudo) user who must always be able to log in | the user in the drop-in's file name, else the user running `sudo` |
| AllowUsers | the users sshd allows today (`sshd -T`), else the admin (+ `forgejo` if that user exists) |
| Switch UsePAM to yes? (only when it is `no` today) | n |
| Include the CIS settings? | y if the current config has `Ciphers` or `Banner` |
| Apply these changes? | n |

Settings the scripts do not manage (a `Port`, say) and `Match` blocks are kept in
the drop-in.

### The change is refused when it could lock you out

Nothing is written when any of these is true:

- AllowUsers would be empty, names a user that does not exist, or leaves out the
  admin user or the user running `sudo`
- the admin user is not in the `sudo` group
- the admin user has no public key that sshd would accept (checked with
  `ssh-keygen`, including the permissions `StrictModes` requires on the home
  folder, `.ssh` and `authorized_keys`)
- the current config already fails `sshd -t`
- there is more than one `*-hardened.conf` in `/etc/ssh/sshd_config.d`
- `sshd_config` has no `Include /etc/ssh/sshd_config.d/*.conf` line
- systemd cannot create the rollback timer

### Confirm the new login

After the new drop-in passes `sshd -t`, the script checks that the admin user is
still allowed in, then reloads sshd. Existing sessions stay open. Then:

```
  >>> Open a NEW terminal now and log in:  ssh <admin>@<host>
  >>> Keep this session open. Without confirmation the old config is restored in 5 minutes
  Did the new login work? Type 'yes' to keep the new config:
```

- Log in from a **new** terminal. If that works, type `yes` in the original one.
- Anything else, or no answer, restores the previous config straight away.
- If your session is cut off, a systemd timer restores the previous config after
  5 minutes. Use `--rollback-minutes 10` (2-30) for more time.

```bash
sudo ./utils/update_server_config.sh ssh --rollback-minutes 10
```

The script then compares every managed setting with what sshd actually uses and
lists any that another file overrides:

```
  [!] sshd does not use these values - an earlier line in /etc/ssh/sshd_config or another file in /etc/ssh/sshd_config.d sets them:
      x11forwarding is 'yes', not 'no'
```

Find the file that sets it with:

```bash
sudo grep -ri '^x11forwarding' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
```

### Servers provisioned by older versions

Older versions wrote the hardened settings into `/etc/ssh/sshd_config` itself,
above the `Include` line. sshd uses the first value it reads for each setting,
so those lines override any drop-in. The script lists them:

```
  /etc/ssh/sshd_config sets these above its Include line, so they override any drop-in:
      15: PermitRootLogin no
      23: UsePAM no
      33: AllowUsers xlvisuals nzcmm
      ...
  Move them into the drop-in (...)? (y/n) [y]:
```

Answering `y` comments them out with a tag. Nothing is deleted:

```
# [moved to 01-xlvisuals-hardened.conf 2026-11-13_043619] AllowUsers xlvisuals nzcmm
```

- Their values carry over: the AllowUsers list stays the same, and so does
  `UsePAM` unless you choose to switch.
- `sshd_config` is backed up and rolled back together with the drop-in.
- The obsolete `Protocol 2` and `ChallengeResponseAuthentication` lines are
  commented out as well.
- Lines below the `Include` are overridden by the drop-in and are left alone.

**UsePAM:** the current provisioning script uses `UsePAM yes`, so PAM's account
and session checks run at every login, also with a key. Older versions set `no`.
When you switch, the script refuses if the admin account is expired or its
password is past the inactivity period (PAM would refuse that login), and warns
about other users in AllowUsers in that state. Check an account with:

```bash
sudo chage -l <user>
```

---

## Update automatic updates

```bash
sudo ./utils/update_server_config.sh updates
```

| Question | Default |
|---|---|
| Install updates automatically? | the current setting |
| Hour to run apt-get update (also runs 12 hours later) | the current hour, else 10 |
| Hour to run apt-get upgrade | the current hour, else one hour after the update |
| Timezone | the current timezone |
| Reboot automatically when an upgrade needs it? | the current setting (Ubuntu's default: no) |
| Reboot time (HH:MM, local) | the current time, else 04:00 |
| Let needrestart restart services automatically? | y if it does today (only asked when needrestart is installed) |

Files written:

| File | Contents |
|---|---|
| `/etc/apt/apt.conf.d/51unattended-upgrades-settings` | on/off and automatic reboot. Read after `20auto-upgrades` and `50unattended-upgrades`, so these values win |
| `/etc/systemd/system/apt-daily.timer.d/override.conf` | update hours, plus up to 60 minutes of random delay |
| `/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf` | upgrade hour, plus up to 60 minutes of random delay |
| `/etc/needrestart/conf.d/50-update-server-config.conf` | needrestart mode |

Checks after writing:

- apt must show the new values. If a later file in `/etc/apt/apt.conf.d`
  overrides them, the change is undone and the files that set the value are named.
- The timers are restarted and must come up again. Otherwise the previous
  schedule is restored.
- The needrestart file must pass `perl -c`.

The timer hours are local time, so changing the timezone moves them (and cron
jobs and log timestamps) as well.

**Automatic reboot** only happens when `/var/run/reboot-required` exists, and only
the `update-notifier-common` package writes it. When you turn automatic reboot on
and that package is missing (minimized installs), the script offers to install
it. A kernel installed before that is not flagged. The health check and
`reboot-required-check` still see it, because they compare the running kernel with
the newest installed one.

Check the schedule afterwards:

```bash
systemctl list-timers apt-daily.timer apt-daily-upgrade.timer
apt-config dump | grep -E 'Periodic|Automatic-Reboot'
```

---

## Other settings

These are applied by re-running the provisioning script with a conf file that
turns everything else off (`INSTALL_DEFAULT=n`).

### Exclude or pin packages

```bash
cat > /tmp/exclude.conf << 'EOF'
INSTALL_DEFAULT=n
USER_CREATE_SUDO_USER=n
USER_USE_CURRENT_USERNAME=y
CREATE_HEALTHSCRIPT=y
EOF
sudo bash ubuntu_provision.sh /tmp/exclude.conf
```

The script asks the two exclusion questions ("exclude packages from automatic
(unattended) upgrades?" and "exclude packages from manual upgrades (pin)?") for
the installed services. Pressing Enter keeps the current state. Set
`EXCLUDE_UNATTENDED_*` / `HOLD_*` in the conf file to skip the questions; see
`ubuntu_provision.conf`.

### Health check script and reboot detection

The health check script is regenerated on every provisioning run; see
[howto-healthscript.md](howto-healthscript.md). To install only the reboot check
helper used by Monit and `upgrade-held-packages`:

```bash
sudo install -m 755 usr/local/sbin/reboot-required-check /usr/local/sbin/
sudo reboot-required-check          # prints why a reboot is needed; exit 1 = needed
```

Then refresh the Monit check (it needs the helper to exist):

```bash
sudo cp etc/monit/conf-available/reboot-required /etc/monit/conf-available/
sudo monit -t && sudo systemctl reload monit
```

---

## Undo a change by hand

Each run's backup folder holds the previous files and a manifest:

```bash
sudo ls /root/config-backup/
sudo cat /root/config-backup/update_config_<time>/manifest
```

`y <path>` means the file existed and its copy is under `files/`. `n <path>`
means the run created it, so delete it to undo.

For SSH, the generated rollback script restores everything that run changed:

```bash
sudo bash /root/config-backup/update_config_<time>/rollback-ssh.sh
```

For the update settings, copy the files back and reload the timers:

```bash
B=/root/config-backup/update_config_<time>
sudo cp -a $B/files/etc/apt/apt.conf.d/51unattended-upgrades-settings /etc/apt/apt.conf.d/   # if listed with y
sudo cp -a $B/files/etc/systemd/system/apt-daily.timer.d/override.conf /etc/systemd/system/apt-daily.timer.d/
sudo cp -a $B/files/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf /etc/systemd/system/apt-daily-upgrade.timer.d/
sudo systemctl daemon-reload && sudo systemctl restart apt-daily.timer apt-daily-upgrade.timer
```

The timezone is not in the backup: set it back with `sudo timedatectl set-timezone <zone>`.

---

## Troubleshooting

**"Another update_server_config.sh is running."** Only one run at a time. Wait
for it, or check `ps aux | grep update_server_config`.

**The rollback timer is still active after a run.** List it and stop it if the
new config is good:

```bash
systemctl list-timers 'ssh-config-rollback-*'
sudo systemctl stop ssh-config-rollback-<time>.timer
```

**Locked out anyway.** Use the provider console and run the rollback script of
the last run (see above), or see [howto-pam-recovery.md](howto-pam-recovery.md)
for GRUB and rescue-image recovery.

**Was a rollback done while I was away?** It is logged:

```bash
sudo journalctl -t update_server_config
```
