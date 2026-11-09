# XUI One — EPG Instant Cache Fix

## The Problem

When you assign an EPG channel to a stream in the **XUI One** admin panel, the stream shows **"no EPG / no data yet"** for up to **24 hours** — even if the EPG source is already fully downloaded and working on other channels.

### Why it happens

XUI One builds per-stream EPG cache files (`content/epg/stream_<id>`) only during the nightly cron:

```
0 0 * * *  /home/xui/bin/php/bin/php /home/xui/crons/epg.php
```

When you assign an EPG to a stream **after** this cron runs, the cache file for that stream simply doesn't exist. The panel reads from these cache files — if there's no file, it shows no EPG.

---

## The Fix

`epg_patch.php` runs **every minute** and generates missing cache files instantly from the EPG data that's already in the database. No XML re-download needed.

**Result:** EPG appears green within **1 minute** of assignment.

---

## Install

### 1. Copy the file

Download it straight from this repository:

```bash
wget -qO /home/xui/crons/epg_patch.php \
  https://raw.githubusercontent.com/cunninghambr/xuione/main/patches/epg-instant-fix/epg_patch.php
chown root:root /home/xui/crons/epg_patch.php
```

Or, if you already have a clone, just `cp epg_patch.php /home/xui/crons/epg_patch.php`.

### 2. Add to root crontab

XUI One locks its crontab as immutable (`chattr +i`), so you need to unlock it first:

```bash
chattr -i /var/spool/cron/crontabs/root

(crontab -l 2>/dev/null; echo "* * * * * /home/xui/bin/php/bin/php /home/xui/crons/epg_patch.php > /dev/null 2>&1") | crontab -

chattr +i /var/spool/cron/crontabs/root
```

> **Why root?** The script connects to MariaDB via unix socket, which on most XUI One servers only allows passwordless access for the system root user.

---

## Verify it works

```bash
# Remove an existing cache file to simulate a fresh assignment
rm /home/xui/content/epg/stream_<YOUR_STREAM_ID>

# Wait 60 seconds, then check
ls /home/xui/content/epg/stream_<YOUR_STREAM_ID>
```

The file should reappear within 1 minute.
