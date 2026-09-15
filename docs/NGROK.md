# Athur — Cross-Network Testing with ngrok

تطبيق الموبايل على **4G/5G لا يستطيع الوصول** إلى `localhost` أو عنوان الشبكة
المحلية للكمبيوتر. لذلك نستخدم **ngrok** لفتح巷道 عام (HTTPS) إلى السيرفر
المحلي، فيعمل التطبيق من **أي شبكة**.

---

## ليه محتاجين ده؟

| السيناريو | بدون ngrok | مع ngrok |
|---|---|---|
| موبايل على نفس الـ WiFi | ✅ يعمل | ✅ يعمل |
| موبايل على 4G/5G | ❌ يفشل | ✅ يعمل |
| صديق في مكان تاني | ❌ يفشل | ✅ يعمل |
| HTTPS / TLS | ❌ | ✅ |

---

## خطوات التشغيل (3 طرفيات)

### 1️⃣ الطرفية الأولى — السيرفر
من `D:\Athur`:
```powershell
.\run_server.ps1
```

### 2️⃣ الطرفية الثانية — ngrok
من `D:\Athur`:
```powershell
.\run_tunnel.ps1
```
هيطبع حاجة زي:
```
  PUBLIC URL: https://marigold-anaconda-visa.ngrok-free.dev
```

### 3️⃣ ابنِ التطبيق على العنوان العام
من `D:\Athur`:
```powershell
.\build_apk.ps1 -ApiBase "https://marigold-anaconda-visa.ngrok-free.dev"
```

> استبدل العنوان باللي ظهر عندك. **العنوان المجاني بيتغير كل مرة تعيد تشغيل
> ngrok**، فلازم تبني (أو تشغّل) من جديد كل مرة.

---

## التأكد إن الـ tunnel شغّال

```powershell
curl.exe -H "ngrok-skip-browser-warning: true" "https://<your-url>/health"
curl.exe -H "ngrok-skip-browser-warning: true" "https://<your-url>/health/ready"
```
المتوقع: `{"status":"ok"}` و `{"status":"ready","database":"up"}`.

---

## لماذا `ngrok-skip-browser-warning`؟

النسخة المجانية من ngrok بتعرض **صفحة HTML تحذيرية** لأول زيارة. لو التطبيق
استقبل HTML بدل JSON، هيفشل. لذلك مضفناه في `ApiConfig` بكل طلب — آمن ولا
يضرّ أي سيرفر عادي.

---

## تعطيل صفحة التحذير نهائيًا (اختياري)

للحصول على عنوان **ثابت** بدون صفحة تحذير، أضف في `ngrok.yml`
(`%LOCALAPPDATA%\ngrok\ngrok.yml`):
```yaml
tunnel: athur
tunnels:
  athur:
    proto: http
    addr: 8080
    domain: athur-dev.example.com   # تتطلب نطاق محجوز على ngrok
```
بعدها شغّل: `ngrok start athur --url "https://..."`

---

## ملاحظات أمنية مهمة

- **لا ترفع** `ngrok.exe` على GitHub (متجاهَل في `.gitignore`).
- **لا تضع** authtoken داخل المشروع.
- الـ tunnel يفضح السيرفر على الإنترنت — استخدمه للتجربة، و**أغلقه** بعد
  الانتهاء (`Ctrl+C` في طرفيته أو اقفل العملية).
- للإنتاج استخدم سيرفرًا حقيًا بنطاق خاص، لا ngrok.
