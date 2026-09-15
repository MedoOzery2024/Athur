# Athur — In-App Updates (زر "Check for Updates")

## الإجابة السريعة

**الزر يشتغل فقط بعد ما يكون فيه GitHub Release فيه ملف APK.**

لو عملت push فقط (بدون Release)، الزر **مش هيلاقي حاجة** ويفضل ساكت.

---

## إزاي الزر بيشتغل (المسار الحقي في الكود)

`AppUpdateService.checkForUpdate()` بيعمل:

```
GET https://api.github.com/repos/MedoOzery2024/Athur/releases/latest
```

ثم:
1. يقرأ `tag_name` (مثل `v1.2.0`) ويقارنه بإصدار التطبيق الحالي.
2. لو فيه إصدار أحدث، يبحث عن ملف ينتهي بـ `.apk` داخل الـ `assets`.
3. يعرض حوار فيه ملاحظات الإصدار + زر تحميل.
4. `downloadApk()` ينزّل الملف داخل التطبيق مع شريط تقدّم.
5. `installApk()` يفتح مثبّت أندرويد.

---

## 🔴 المشاكل الثلاث اللي كانت بتخلي الزر مش شغال

| # | المشكلة | الحالة |
|---|---|---|
| 1 | `_owner = 'medo444'` (غلط) | ✅ **اتصلحت** → `MedoOzery2024` |
| 2 | مفيش **Release**، بس CI artifact | ✅ **اتصلحت** → أضفت `publish-apk.yml` |
| 3 | الـ repo **private** | ⚠️ **محتاج قرار منك** |

### بخصوص المشكلة 3 (مهمة)

GitHub API **يرجّع 404** لـ releases الـ repo الخاص لو الطلب مش مصادق.
التطبيق على الموبايل **مش بيبعت توكن GitHub** (ومينفعش — ده سر خطير).

**الحلول:**

| الحل | يُنصح به؟ |
|---|---|
| **اجعل الـ repo عام (public)** | ✅ الأبسط والأنسب لتطبيق تجريبي |
| استخدم سيرفر خاص يقدّم `version.json` + APK | ✅ للإنتاج (بدون الاعتماد على GitHub) |
| اعمل PAT داخل التطبيق | ❌ **خطر أمني — لا تفعل** |

> الطريقة الاحترافية للإنتاج: بدّل الزر ليقرأ من **سيرفرك** (`/api/v1/app/latest`)
> بدل GitHub. جدول `app_releases` جاهز في قاعدة البيانات لهذا الغرض.

---

## خطوات التفعيل (خطوة بخطوة)

### 1. أضف الأسرار في GitHub
`Settings → Secrets and variables → Actions → New repository secret`

| السر | القيمة |
|---|---|
| `GOOGLE_SERVICES_JSON` | محتوى `app/android/app/google-services.json` كامل |
| `ATHUR_API_BASE` | عنوان السيرفر العام، مثل `https://xxxx.ngrok-free.dev` |

### 2. اجعل الـ repo عامًا (عشان الزر يشتغل بدون توكن)
`Settings → General → Danger Zone → Change visibility → Public`

### 3. اطلق workflow الـ release
- أي `push` على `main` بيطلق `Publish APK Release` أوتوماتيك.
- أو يدويًا: `Actions → Publish APK Release → Run workflow`.

### 4. تأكد إن الـ Release اتكون
```
https://github.com/MedoOzery2024/Athur/releases/latest
```
لازم تلاقي ملف `app-release.apk` مرفق.

### 5. اختبر الزر
افتح التطبيق → **Settings → Check for updates**.

> لو التطبيق بنفس إصدار الـ release، **مش هيظهر تحديث** (والصح كده).
> عشان تجرّب: غيّر الإصدار في `app/pubspec.yaml` (مثلاً `1.0.1+2`) واعمل push،
> وبعدين افتح التطبيق القديم ودوس "Check for updates".

---

## كيف ترفع إصدار نسخة جديدة (الإجراء الصحيح)

```powershell
# 1) غيّر الإصدار في app/pubspec.yaml
#    version: 1.0.1+2      <- اللي بعد + لازم يزيد دائمًا (versionCode)

# 2) ارفع التغيور
git add app/pubspec.yaml
git commit -m "release: v1.0.1"
git push origin main

# 3) الـ workflow هيبني APK ويعمل Release تلقائيًا (tag: v1.0.1)
```

⚠️ **لا تُصدّر نفس الـ versionCode مرتين** — أندرويد يرفض التثبيت.

---

## ملاحظة أمنية عن التحديث

حاليًا الـ APK موقّع بمفتاح **debug** (انظر `build.gradle.kts`). ده **مقبول
للتجربة فقط**، لكن التحديث الرسمي يجب أن يكون موقّعًا بمفتاح إصدار حقي،
وإلا يرفض أندرويد التثبيت فوق نسخة موقّعة بمفتاح مختلف.

راجع `docs/CREDENTIALS.md` (قسم مفتاح الـ APK) لتفعيل مفتاح الإصدار.
