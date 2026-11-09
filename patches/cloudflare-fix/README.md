# XUI ONE behind Cloudflare — Fix Guide

Steps to make the XUI ONE panel login work reliably with the Cloudflare
proxy enabled (orange cloud), to be repeated after a clean reinstall of the
panel.

## Problem context

Without this configuration, panel login (`https://yourdomain.com/PATH/login`)
works intermittently: the user logs in, the dashboard loads, but seconds or
minutes later it redirects back to the login page in a loop. The root cause
is that Nginx sees Cloudflare's edge server IPs instead of the visitor's
real IP, which breaks session validations tied to IP (e.g. "Restrict to
Same IP").

## 1. Enable Cloudflare/CDN in the database

In some XUI ONE builds (confirmed on v1.5.13) the **"Enable Cloudflare"**
toggle does not appear in the UI (Management → General Settings → General),
even though the backend supports it. Check your version's UI first. If it's
missing, enable it via SQL:

```bash
mysql -u root xui -e "UPDATE settings SET cloudflare = 1, allow_cdn_access = 1;"
```

This is the most important step: without these flags set to `1`, the
`root_signals.php` cron job (runs every minute as root) detects that
Cloudflare is "not authorized" and automatically empties the file from step
3 on its next run. Do this step first.

## 2. Configure the real IP header in nginx.conf

Edit `/home/xui/bin/nginx/conf/nginx.conf`, inside the `http{}` block
(around line 38):

```nginx
real_ip_header CF-Connecting-IP;
```

(it defaults to `X-Forwarded-For;`, which does not work with Cloudflare).

## 3. Populate realip_cloudflare.conf with Cloudflare's IP ranges

`/home/xui/bin/nginx/conf/realip_cloudflare.conf` ships empty by default.
Fill it like this:

```bash
cat > /home/xui/bin/nginx/conf/realip_cloudflare.conf << 'EOF'
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;
EOF
chmod 550 /home/xui/bin/nginx/conf/realip_cloudflare.conf
chown xui:xui /home/xui/bin/nginx/conf/realip_cloudflare.conf
```

**Do not put `real_ip_header` inside this file** — it belongs only in
`nginx.conf` (step 2); having it in both places makes nginx fail with a
duplicate directive error.

Check the up-to-date range list periodically at
[cloudflare.com/ips](https://www.cloudflare.com/ips/) in case they change.

## 4. Test syntax and reload nginx

```bash
sudo -u xui /home/xui/bin/nginx/sbin/nginx -t
sudo /home/xui/bin/nginx/sbin/nginx -s reload
```

## 5. Recommended panel setting (Servers → Advanced)

- **HTTPS Ports**: use only ports Cloudflare actually proxies:
  `443, 2053, 2083, 2087, 2096, 8443`. If you need more than one port, pick
  from this list. Any port outside it (e.g. `8000`) is **not proxied by
  Cloudflare at all** — traffic to it goes straight to the origin server,
  which is exactly why it worked as a bypass, and exactly why it should be
  removed once the real fix (steps 1-4) is in place: it exposes the origin
  while skipping Cloudflare's protection entirely.
- For reference, Cloudflare's proxied HTTP ports are:
  `80, 8080, 8880, 2052, 2082, 2086, 2095`.

## 6. Final check

- Login stays stable at `https://yourdomain.com/PATH/login` with Cloudflare
  on (orange cloud), with no logout loop.
- (Optional, troubleshooting only) temporarily enable `access_log` in
  `nginx.conf` to confirm real visitor IPs show up instead of Cloudflare
  edge IPs (`172.68.x.x` and other Cloudflare ranges) — and **set it back to
  `off`** when done, so logs don't grow indefinitely.

## Useful diagnostics if it breaks again

```bash
# Check if the file is being emptied and when
ls -la --time-style=full-iso /home/xui/bin/nginx/conf/realip_cloudflare.conf

# Confirm the flag values in the DB
mysql -u root xui -e "SELECT cloudflare, allow_cdn_access FROM settings;"

# Capture in real time which process touches the file (root, via cron)
strace -f -e trace=openat,write,truncate,ftruncate -s 200 \
  -o /tmp/strace_signals.log \
  /home/xui/bin/php/bin/php /home/xui/crons/root_signals.php
grep -n 'realip_cloudflare\|Disabling Cloudflare' /tmp/strace_signals.log
```
