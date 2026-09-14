# Restoring a Broken PAM Stack on Ubuntu/Debian

If PAM is misconfigured, users cannot authenticate — including sudo. This guide covers recovery from least to most invasive, starting with the simplest option.

---

## Option 1: Fix via Root Console (Easiest)

If you can access a root console (cloud provider web console, VNC, IPMI), log in as root directly — no sudo needed.

```bash
pam-auth-update --force
```

This regenerates `common-auth`, `common-password`, `common-session`, and `common-account` from installed package defaults, wiping any broken customisations.

Then clear any faillock strikes on affected users:

```bash
faillock --user YOUR_USERNAME --reset
```

Set a known password while you're here:

```bash
passwd YOUR_USERNAME
```

Test sudo from a new SSH session before closing the root console.

---

## Option 2: Recovery via GRUB Single-User Mode

Use this when you have no root console access but do have physical or IPMI/iDRAC access to see the boot screen.

### Step 1 — Enter GRUB

Reboot the machine. At the GRUB menu, highlight the default boot entry and press **`e`** to edit it.

If the GRUB menu doesn't appear, hold or tap **Shift** (BIOS) or **Escape** (UEFI) during boot.

### Step 2 — Edit the Boot Parameters

Find the line starting with `linux` — it will look something like:

```
linux /boot/vmlinuz-... root=UUID=... ro quiet splash
```

Using the arrow keys, navigate to the end of that line and change:

- `ro` → `rw`
- Remove `quiet splash`
- Append `init=/bin/bash`

The end of the line should look like:

```
... root=UUID=... rw init=/bin/bash
```

Press **Ctrl+X** or **F10** to boot.

### Step 3 — Remount the Filesystem (if needed)

You'll drop to a root shell. If the filesystem is read-only:

```bash
mount -o remount,rw /
```

### Step 4 — Fix PAM

```bash
pam-auth-update --force
```

Clear faillock:

```bash
faillock --user YOUR_USERNAME --reset
```

Reset the password:

```bash
passwd YOUR_USERNAME
```

### Step 5 — Reboot Cleanly

```bash
exec /sbin/init
```

Or if that fails:

```bash
/sbin/reboot -f
```

---

## Option 3: Recovery via GRUB Recovery Mode

An alternative to editing boot parameters manually.

### Step 1 — Enter GRUB

Reboot and hold **Shift** (BIOS) or tap **Escape** (UEFI) to show the GRUB menu.

### Step 2 — Select Recovery Mode

Choose **Advanced options for Ubuntu** → select the entry ending in **(recovery mode)**.

### Step 3 — Drop to Root Shell

In the recovery menu, select **root — Drop to root shell prompt**.

If the filesystem is read-only:

```bash
mount -o remount,rw /
```

### Step 4 — Fix PAM

```bash
pam-auth-update --force
faillock --user YOUR_USERNAME --reset
passwd YOUR_USERNAME
```

### Step 5 — Resume Normal Boot

```bash
exit
```

Select **Resume** in the recovery menu, or reboot:

```bash
reboot
```

---

## Option 4: Mount the Disk from Another System

Use this when the system won't boot at all, or GRUB is inaccessible.

### On a VPS

Most cloud providers let you detach the disk and attach it to a rescue VM, or boot into a rescue image directly from the provider control panel. Do that, then:

```bash
# Find your disk
lsblk

# Mount it (adjust partition as needed, commonly /dev/sdb1 or /dev/vda1)
mount /dev/sdb1 /mnt

# Chroot into it
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys
chroot /mnt

# Fix PAM
pam-auth-update --force
faillock --user YOUR_USERNAME --reset
passwd YOUR_USERNAME

# Exit and unmount
exit
umount /mnt/dev /mnt/proc /mnt/sys /mnt
```

### On Physical Hardware

Boot from a Ubuntu live USB, open a terminal, and follow the same chroot steps above.

---

## Verifying PAM is Fixed

After any of the above, check the restored files look sane:

```bash
grep -E 'pam_unix|pam_faillock|pam_pwquality|pam_pwhistory' \
    /etc/pam.d/common-auth \
    /etc/pam.d/common-password
```

Expected order in `common-auth`:

```
pam_faillock.so preauth      ← must be first
pam_unix.so                  ← primary auth
pam_faillock.so authfail     ← record failure
pam_faillock.so authsucc     ← clear on success
pam_deny.so
pam_permit.so
```

Expected order in `common-password`:

```
pam_pwquality.so             ← quality check first
pam_pwhistory.so use_authtok ← history check second
pam_unix.so      use_authtok ← write hash last (use_authtok once only)
```

---

## Quick Reference

| Situation | Best Option |
|---|---|
| Cloud root console available | Option 1 — `pam-auth-update --force` |
| No console, can see GRUB | Option 2 or 3 |
| System won't boot | Option 4 — rescue/chroot |

---

## Prevention

When modifying PAM files in scripts, always:

- **Guard against re-runs** — check for a marker before inserting lines
- **Never use blind `sed -i` appends** on PAM files — they stack on every run
- **Test in a VM first** before applying to production
- **Keep a root console session open** while testing PAM changes
- **Know that `pam-auth-update --force` exists** — it's always the fastest recovery path
