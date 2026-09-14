# Athur — Credentials & Configuration Checklist

This is the **exact** list of external values the project needs. Nothing here is
invented by the assistant, and no secret is ever hardcoded or committed.

> **Security rule (enforced):** anything marked 🔒 stays **server-side only**,
> supplied as an environment variable or secret file. It must never appear in
> the Flutter app, in source code, or in the repository.

---

## 1. Already provided ✅

| Item | Location | Used for |
|---|---|---|
| Athur logo (1024×1024 PNG) | `app/assets/images/logo.png` | app icon, splash, brand UI |
| Custom ringtone (MP3) | `app/assets/audio/ringtone.mp3` | incoming + outgoing call ringing |

---

## 2. Firebase Console — needed at **Phase 7** (notifications) and **Phase 3** (phone OTP)

| # | Value | Where to find it | Sensitivity |
|---|---|
| 1 | `google-services.json` | Project settings → Your apps → **Android** app | Public-ish, but do **not** commit |
| 2 | `GoogleService-Info.plist` (only if we build iOS) | Project settings → Your apps → **iOS** app | Public-ish, do not commit |
| 3 | **Web API key** + **Project ID** | Project settings → General | Public (safe in client config) |
| 4 | Service-account JSON | Project settings → Service accounts → *Generate new private key* | 🔒 **SECRET — server only** |
| 5 | Cloud Messaging (FCM) enabled | Project settings → Cloud Messaging | — |
| 6 | Phone Authentication enabled | Authentication → Sign-in method → Phone | — |

**How to send #1–#3:** place `google-services.json` in `app/android/app/`, and
tell me the Web API key + Project ID. **Do not paste the service-account JSON
into chat** — save it to a file outside the repo and give me its path.

---

## 3. Metered.ca — PROVIDED ✅ (Phase 9 partially complete)

| # | Value | Status |
|---|---|---|
| 1 | TURN hostname = `athur.metered.live` | ✅ provided |
| 2 | API key | ✅ provided, stored in `.env` (git-ignored) |

**Verified live** with `dart run tool/verify_turn.dart` — the server obtained:
STUN (2× Google + 1× Metered) and 4 TURN relay endpoints (UDP, TCP-80,
TLS-443, TURN-over-TLS).

> ⚠️ **Action required:** the API key was shared in chat, so treat it as
> exposed. Rotate it in the Metered dashboard and update `ATHUR_METERED_API_KEY`
> in `.env`.
>
> Note: the `Secret Key` presented earlier returns **401** on this account; only
> the API key works. TURN features use the API key.

---

## 4. Google OAuth (Sign-in) — needed during **Phase 3**

| # | Value | Where to find it | Sensitivity |
|---|---|
| 1 | **Client ID** (Android, package name + SHA-1) | Google Cloud Console → Credentials | Public (safe in app) |
| 2 | **Client Secret** | Google Cloud Console → Credentials | 🔒 **SECRET — server only** |
| 3 | Consent screen configured + test users | Google Cloud Console → OAuth consent | — |

For Android I need the app's **SHA-1** fingerprint. Get it with:
```powershell
cd D:\Athur\app\android
.\gradlew signingReport
```

---

## 5. Microsoft OAuth (Sign-in) — needed during **Phase 3**

| # | Value | Where to find it | Sensitivity |
|---|---|
| 1 | **Application (client) ID** | Azure Portal → App registrations | Public |
| 2 | **Directory (tenant) ID** — or use `common` for multi-tenant | Azure Portal | Public |
| 3 | **Client Secret** | Azure Portal → Certificates & secrets | 🔒 **SECRET — server only** |
| 4 | Redirect URI configured | Azure Portal → Authentication | Public |

---

## 6. Email OTP provider — needed during **Phase 3**

**Decision required from you:** which provider? (SendGrid / AWS SES / Resend /
Postmark / other). Then:

| # | Value | Sensitivity |
|---|---|---|
| 1 | API key / SMTP credentials | 🔒 **SECRET — server only** |
| 2 | Verified sender address (From:) | Public |
| 3 | Sender domain + DNS records verified | Public |

---

## 7. Object storage for media — needed during **Phase 6**

**Decision required:** AWS S3 / Cloudflare R2 / MinIO (self-hosted) / other. Then:

| # | Value | Sensitivity |
|---|---|---|
| 1 | Endpoint / region | Public |
| 2 | Bucket name | Public |
| 3 | Access key ID | 🔒 **SECRET — server only** |
| 4 | Secret access key | 🔒 **SECRET — server only** |

The server issues short-lived signed URLs; the app never holds storage keys.

---

## 8. Android release signing — needed during **Phase 17** (update system)

| # | Value | Sensitivity |
|---|---|---|
| 1 | Release keystore (`.jks`) | 🔒 **SECRET — guard carefully** |
| 2 | Keystore password | 🔒 **SECRET** |
| 3 | Key alias + key password | 🔒 **SECRET** |
| 4 | The APK's **signing certificate SHA-256** | Public (used for update verification) |

**Losing the keystore means you can never update an installed Athur app again.**
Keep at least two backups in separate secure locations.

---

## 9. Where secrets live

| Context | Mechanism |
|---|---|
| Local development | `.env` file (git-ignored), copied from `.env.example` |
| Server runtime | Real environment variables |
| CI/CD | GitHub Actions **repository secrets** |
| Firebase service account | File outside the repo, path in an env var |

**Never** commit a secret. `.gitignore` already blocks the common ones.
