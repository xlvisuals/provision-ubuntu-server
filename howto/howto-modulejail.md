# Howto: (Re)install Modulejail

## Background

[Modulejail](https://github.com/jnuyens/modulejail) detects unused kernel
modules and blacklists them via `/etc/modprobe.d/modulejail-blacklist.conf`.
This reduces the kernel attack surface by preventing unused modules from being
loaded.

**Important:** Modulejail should only be run after all services are installed
and running. It detects which modules are currently in use and blacklists
everything else — running it before all services are up will blacklist modules
those services need.

---

## Conf file

```bash
cat > /tmp/modulejail.conf << 'EOF'
INSTALL_DEFAULT=n
USER_CREATE_SUDO_USER=n
USER_USE_CURRENT_USERNAME=y
CONFIGURE_MODULEJAIL=y
EOF
```

Run:

```bash
sudo bash ubuntu_provision.sh /tmp/modulejail.conf
```

---

## Verify

**Check the blacklist file was created:**

```bash
cat /etc/modprobe.d/modulejail-blacklist.conf
```

**Check how many modules were blacklisted:**

```bash
grep -c "^blacklist" /etc/modprobe.d/modulejail-blacklist.conf
```

**The blacklist takes effect on next reboot.** To verify a module is blocked
after reboot:

```bash
sudo modprobe <modulename>
# Should return: modprobe: ERROR: could not insert '<modulename>': Operation not permitted
```

---

## Revert

To undo the blacklist:

```bash
sudo rm /etc/modprobe.d/modulejail-blacklist.conf
sudo update-initramfs -u
```

Then reboot.
