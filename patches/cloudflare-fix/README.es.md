# XUI ONE detrás de Cloudflare — Guía de solución

Pasos para que el login del panel XUI ONE funcione de forma estable con el
proxy de Cloudflare activo (nube naranja), a repetir después de una
reinstalación limpia del panel.

## Contexto del problema

Sin esta configuración, el login al panel XUI (`https://tudominio.com/RUTA/login`)
funciona de forma intermitente: el usuario se loguea, carga el dashboard, pero
segundos/minutos después vuelve a redirigir al login en un ciclo. La causa es
que Nginx ve las IPs de los edge servers de Cloudflare en vez de la IP real
del visitante, lo que rompe validaciones de sesión atadas a IP (ej. "Restrict
to Same IP").

## 1. Activar Cloudflare/CDN en la base de datos

En algunas builds de XUI ONE (confirmado en v1.5.13) el toggle **"Enable
Cloudflare"** no aparece en la UI (Management → General Settings → General),
aunque el backend sí lo soporta. Revisa primero si tu versión lo muestra ahí.
Si no aparece, actívalo por SQL:

```bash
mysql -u root xui -e "UPDATE settings SET cloudflare = 1, allow_cdn_access = 1;"
```

Este es el paso más importante: sin estas banderas en `1`, el cron
`root_signals.php` (corre cada minuto como root) detecta que Cloudflare "no
está autorizado" y vacía automáticamente el archivo del paso 3 en su
siguiente ejecución. Haz este paso primero.

## 2. Configurar el real IP header en nginx.conf

Edita `/home/xui/bin/nginx/conf/nginx.conf`, dentro del bloque `http{}`
(línea ~38):

```nginx
real_ip_header CF-Connecting-IP;
```

(por defecto viene como `X-Forwarded-For;`, que no sirve con Cloudflare).

## 3. Rellenar realip_cloudflare.conf con los rangos de Cloudflare

El archivo `/home/xui/bin/nginx/conf/realip_cloudflare.conf` viene vacío de
fábrica. Rellénalo así:

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

**No incluyas `real_ip_header` dentro de este archivo** — va solo en
`nginx.conf` (paso 2); si lo pones en ambos lados, nginx falla por directiva
duplicada.

Revisa periódicamente la lista actualizada de rangos en
[cloudflare.com/ips](https://www.cloudflare.com/ips/) por si cambian.

## 4. Verificar sintaxis y recargar nginx

```bash
sudo -u xui /home/xui/bin/nginx/sbin/nginx -t
sudo /home/xui/bin/nginx/sbin/nginx -s reload
```

## 5. Configuración recomendada en el panel (Servers → Advanced)

- **HTTPS Ports**: usa solo los puertos que Cloudflare realmente proxea:
  `443, 2053, 2083, 2087, 2096, 8443`. Si necesitas más de uno, elige de esta
  lista. Cualquier puerto fuera de ella (ej. `8000`) **Cloudflare no lo
  proxea en absoluto** — el tráfico va directo al servidor origen, que es
  justo por lo que funcionaba como bypass, y justo por lo que debe
  eliminarse una vez aplicado el fix real (pasos 1-4): expone el origen
  saltándose por completo la protección de Cloudflare.
- Como referencia, los puertos HTTP que Cloudflare proxea son:
  `80, 8080, 8880, 2052, 2082, 2086, 2095`.

## 6. Confirmación final

- Login estable en `https://tudominio.com/RUTA/login` con Cloudflare en nube
  naranja, sin ciclo de logout.
- (Opcional, solo para diagnosticar) activa temporalmente `access_log` en
  `nginx.conf` para verificar que aparecen las IPs reales de los visitantes
  en vez de IPs de borde de Cloudflare (rango `172.68.x.x` u otros rangos de
  Cloudflare) — y **vuelve a ponerlo en `off`** cuando termines, para no dejar
  logs creciendo indefinidamente.

## Diagnóstico útil si vuelve a fallar

```bash
# Ver si el archivo se está vaciando y cuándo
ls -la --time-style=full-iso /home/xui/bin/nginx/conf/realip_cloudflare.conf

# Confirmar el valor de las banderas en BD
mysql -u root xui -e "SELECT cloudflare, allow_cdn_access FROM settings;"

# Capturar en tiempo real qué proceso toca el archivo (root, vía cron)
strace -f -e trace=openat,write,truncate,ftruncate -s 200 \
  -o /tmp/strace_signals.log \
  /home/xui/bin/php/bin/php /home/xui/crons/root_signals.php
grep -n 'realip_cloudflare\|Disabling Cloudflare' /tmp/strace_signals.log
```
