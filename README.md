# XHTTP-Wasmer

نصب خودکار پروکسی **VLESS+XHTTP+TLS** با Relay روی **Wasmer Edge**

> نسخه جایگزین [XHTTP-Installer](https://github.com/avacocloud/XHTTP-Installer) — به جای Netlify/Vercel از Wasmer Edge استفاده می‌کند.

---

## معماری

```
کاربر ایران
    │  (VLESS+XHTTP+TLS — شبیه HTTPS معمولی)
    ▼
Wasmer Edge Worker
  [edge.js / WinterCG relay]
    │  (HTTPS به سرور اصلی)
    ▼
سرور Ubuntu شما
  [Xray-core – VLESS+XHTTP+TLS]
    │
    ▼
اینترنت آزاد
```

ترافیک از طریق زیردامنه‌ی Wasmer Edge عبور می‌کند؛ IP سرور اصلی مخفی می‌ماند.

---

## پیش‌نیازها

| مورد | جزئیات |
|------|---------|
| سرور | Ubuntu 20.04 یا بالاتر، دسترسی root |
| پورت‌ها | 80 و 443 باید آزاد باشند |
| منابع | حداقل 1 vCPU + 512 MB RAM |
| دامنه | یک ساب‌دامین با DNS A record به IP سرور |
| Wasmer | حساب رایگان روی [wasmer.io](https://wasmer.io) |
| توکن | از [wasmer.io/settings/access-tokens](https://wasmer.io/settings/access-tokens) |

---

## نصب سریع

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_REPO/main/bootstrap.sh)
```

اسکریپت مراحل زیر را به‌صورت خودکار انجام می‌دهد:

1. بررسی سیستم‌عامل و پورت‌ها
2. نصب Xray-core، acme.sh، Wasmer CLI
3. دریافت تنظیمات از کاربر (دامنه، ایمیل، توکن Wasmer)
4. صدور گواهی SSL از Let's Encrypt
5. پیکربندی Xray با پروتکل VLESS+XHTTP+TLS
6. دیپلوی relay worker روی Wasmer Edge
7. تست کامل زنجیره relay → Xray
8. نمایش لینک VLESS آماده برای کلاینت

---

## ساختار پروژه

```
XHTTP-Wasmer/
├── bootstrap.sh              ← entry point (curl | bash)
├── install.sh                ← اسکریپت اصلی نصب
├── Deploy-Ubuntu.sh          ← alias برای install.sh
├── deploy/
│   └── worker/
│       ├── src/
│       │   └── index.js      ← WinterCG relay worker
│       ├── wasmer.toml       ← تعریف پکیج Wasmer
│       └── app.yaml          ← تنظیمات app روی Wasmer Edge
├── README.md                 ← این فایل (فارسی)
└── README_EN.md              ← مستندات انگلیسی
```

---

## پروتکل XHTTP چیست؟

XHTTP یک transport layer اختصاصی در Xray-core است که ترافیک VPN را درون درخواست‌های HTTP/HTTPS معمولی پنهان می‌کند. مزایا:

- **DPI resistance**: DPI نمی‌تواند آن را از HTTPS معمولی تشخیص دهد
- **CDN compatible**: از طریق CDN هایی مثل Wasmer Edge، Cloudflare، Netlify قابل relay است
- **Padding**: بایت‌های تصادفی به پکت‌ها اضافه می‌کند تا الگو شناسایی نشود
- **نیاز به TLS**: امنیت لایه انتقال تضمین می‌شود

---

## تنظیمات دستی (بدون اسکریپت)

### ۱. ساخت توکن Wasmer

به [wasmer.io/settings/access-tokens](https://wasmer.io/settings/access-tokens) بروید و یک توکن جدید بسازید.

### ۲. پیکربندی deploy/worker/app.yaml

```yaml
kind: wasmer.io/App.v0
name: YOUR_NAMESPACE/xhttp-relay

env:
  TARGET_DOMAIN: "vpn.yourdomain.com"   # دامنه سرور Xray شما
  RELAY_PATH:    "/your-secret-path"    # مسیر XHTTP
  RELAY_KEY:     "your-secret-key"      # کلید احراز هویت
```

### ۳. دیپلوی

```bash
cd deploy/worker
wasmer login YOUR_TOKEN
wasmer deploy
```

### ۴. تنظیم Xray روی سرور

در `/usr/local/etc/xray/config.json`:

```json
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "YOUR-UUID", "flow": ""}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "xhttp",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "/etc/xray/certs/yourdomain.crt",
          "keyFile":         "/etc/xray/certs/yourdomain.key"
        }]
      },
      "xhttpSettings": {
        "path":          "/your-secret-path",
        "host":          "vpn.yourdomain.com",
        "mode":          "auto",
        "xPaddingBytes": "100-1000",
        "headers":       {"x-relay-key": "your-secret-key"}
      }
    }
  }]
}
```

---

## لینک VLESS کلاینت

```
vless://UUID@YOUR_APP.wasmer.app:443?encryption=none&security=tls&sni=YOUR_APP.wasmer.app&type=xhttp&path=/your-path&host=YOUR_APP.wasmer.app&xPaddingBytes=100-1000#XHTTP-Wasmer
```

این لینک را در:
- **v2rayN** (Windows)
- **Nekoray** (Windows/Linux)
- **Hiddify** (Android/iOS/Windows)
- **V2Box** (iOS)

وارد کنید.

---

## عیب‌یابی

| مشکل | راه‌حل |
|------|---------|
| Xray start نمی‌شود | `journalctl -u xray -n 50` |
| گواهی SSL صادر نمی‌شود | پورت 80 باید باز باشد، DNS باید به IP سرور اشاره کند |
| Wasmer deploy خطا می‌دهد | توکن را بررسی کنید: `wasmer whoami` |
| Relay 502 برمی‌گرداند | `TARGET_DOMAIN` در app.yaml را بررسی کنید |
| کلاینت وصل نمی‌شود | UUID، path و SNI را در لینک بررسی کنید |

---

## مجوز

GPL-3.0 — برگرفته از [avacocloud/XHTTP-Installer](https://github.com/avacocloud/XHTTP-Installer)
