# Athur

تطبيق تواصل آمن ب趺 implementations للمحادثات والمكالمات الصوتية والفيديو.

## الميزات

- ✅ محادثات نصية فورية (WebSocket)
- ✅ مكالمات صوتية وفيديو (WebRTC)
- ✅ عزل الضوضاء وجودة صوت عالية
- ✅ مشاركة الصور والفيديو والملفات
- ✅ تسجيل الرسائل الصوتية
- ✅ طلبات الصداقة
- ✅ إشعارات فورية (FCM)
- ✅ تحديث التطبيق من داخله

## النشر على GitHub من VS Code

### الخطوة 1: تثبيت Git
1. حمّل Git من https://git-scm.com
2. ثبته وأعد تشغيل VS Code

### الخطوة 2: إعداد Git
افتح Terminal في VS Code (Ctrl + `) واكتب:

```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

### الخطوة 3: إنشاء مستودع على GitHub
1. اذهب إلى https://github.com/new
2. اكتب اسم المستودع: `Athur`
3. اضغط "Create repository"

### الخطوة 4: رفع الكود
```bash
# الانتقال إلى مجلد المشروع
cd D:\Athur

# تهيئة Git
git init

# إضافة جميع الملفات
git add .

# إنشاء أول commit
git commit -m "Initial commit"

# ربط المستودع
git remote add origin https://github.com/YOUR_USERNAME/Athur.git

# رفع الكود
git push -u origin main
```

### الخطوة 5: إنشاء إصدار جديد
```bash
# إنشاء tag جديد
git tag v1.0.0

# رفع tag
git push origin v1.0.0
```

سيتم إنشاء Release تلقائياً مع APK جاهز للتحميل.

## التشغيل المحلي

### الخادم
```bash
cd server
dart pub get
dart bin/server.dart
```

### التطبيق
```bash
cd app
flutter pub get
flutter run
```

## بناء APK
```bash
cd app
flutter build apk --release
```

الـ APK سيكون في:
`app/build/app/outputs/flutter-apk/app-release.apk`

## المتطلبات

- Flutter SDK 3.27.0+
- Dart SDK 3.13.2+
- PostgreSQL 16+
- Firebase Project

## الرخصة

MIT License
