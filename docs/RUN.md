# Athur — How to Run (Website & APK)

نسخة قصيرة وعملية. **كل الأوامر تُنفَّذ داخل مجلد المشروع الرئيسي `D:\Athur`**
إلا لو مكتوب غير ذلك.

---

## ⚡ الطريقة الأسهل — سكربتات جاهزة

### 1. تشغيل قاعدة البيانات + السيرفر

**الطرفية الأولى** (من `D:\Athur`):
```powershell
.\run_server.ps1
```

### 2. تشغيل التطبيق كموقع (Website)

**الطرفية الثانية** (من `D:\Athur`):
```powershell
.\run_web.ps1
```
هيفتح المتصفح تلقائيًا على التطبيق.

### 3. بناء ملف APK

عند الانتهاء من التطوير (من `D:\Athur`):
```powershell
.\build_apk.ps1
```
الملف الناتج:
```
app\build\app\outputs\flutter-apk\app-release.apk
```

---

## 🔧 الأوامر اليدوية (لو السكربتات مش شغالة)

### تشغيل السيرفر
```powershell
cd D:\Athur\server
dart run bin\server.dart
```
للتأكد إنه شغّال:
```powershell
Invoke-RestMethod http://localhost:8080/health
Invoke-RestMethod http://localhost:8080/health/ready
```

### تشغيل كموقع
```powershell
cd D:\Athur\app
flutter run -d chrome --dart-define=ATHUR_API_BASE=http://localhost:8080
```

### بناء APK
```powershell
cd D:\Athur\app
flutter build apk --release
```

### بناء نسخة الويب للنشر
```powershell
cd D:\Athur\app
flutter build web --release --no-wasm-dry-run
```
النتيجة في: `app\build\web\` — ارفعها على أي استضافة ثابتة (Netlify، Vercel، سيرفرك).

> **ملاحظة مهمة:** فلاج `--no-wasm-dry-run` ضروري حاليًا لأن حزمة `record`
> بتفشل في فحص WASM. التأثيره: البناء يخرج JavaScript عادي (مش WASM)،
> وده تمام للموبايل والويب.

---

## 🛠️ تهيئة جهازك (لمرة واحدة)

### Flutter على PATH
```powershell
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";D:\flutter\bin", "User")
```
ثم **أعد تشغيل VS Code**.

### التحقق من كل شيء
```powershell
cd D:\Athur\app
flutter doctor
flutter analyze
flutter test
```

---

## 📋 المتطلبات

| المكوّن | الحالة عندك |
|---|---|
| Flutter 3.47.2 / Dart 3.13.2 | ✅ |
| Android Studio JBR (JDK 25) | ✅ |
| Android SDK (platform 37) | ✅ |
| PostgreSQL 16 (شغّال) | ✅ |
| `.env` جاهز (Metered + Firebase + JWT) | ✅ |
| 7 migrations مطبّقة (70 جدول) | ✅ |

---

## ✅ اختبارات التحقق

```powershell
# التطبيق
cd D:\Athur\app
flutter analyze     # يجب: No issues found
flutter test

# السيرفر
cd D:\Athur\server
dart analyze        # يجب: No issues found
dart test           # 37 اختبار

# قاعدة البيانات
cd D:\Athur
psql $env:ATHUR_DATABASE_URL -v ON_ERROR_STOP=1 -f db\scripts\schema_test.sql
# يجب أن يظهر: ALL SCHEMA TESTS PASSED
```
