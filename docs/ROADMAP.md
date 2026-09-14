# Athur — Implementation Roadmap

Status legend: ✅ done & verified · 🔨 in progress · ⬜ not started ·
⏸️ **blocked on a credential or decision from you**

---

## Phase 1 — Project scaffold, architecture, design system ✅

- ✅ Monorepo created (`app/`, `server/`, `db/`, `infra/`, `docs/`).
- ✅ Flutter app scaffolded (`com.athur`, Android + iOS + Windows).
- ✅ Logo + ringtone moved into `app/assets/` and registered in `pubspec.yaml`.
- ✅ Black/gold design system: colours, typography, spacing/radius/duration
  tokens, full dark `ThemeData`, themed global scrollbars.
- ✅ Screens: animated brand splash, home shell with custom bottom nav, four
  tabs with honest empty states, working About dialog.
- ✅ Launcher icons + native splash generated from the real logo.
- ✅ `flutter analyze` clean; **5/5** widget tests pass.
- ✅ Backend scaffold (`Dart/Shelf`): env-driven config (fails fast, redacts
  secrets), structured error contract, JSON helpers, health/version routes,
  PostgreSQL pool, graceful shutdown.
- ✅ `dart analyze` clean; **14/14** server tests pass.

## Phase 2 — Database schema & backend foundation 🔨

- ✅ 7 migrations written covering every required domain (identity, social
  graph, messaging, groups, media, presence, calls, notifications, social,
  stories, live, releases, audit).
- ✅ Schema verification test written (`db/scripts/schema_test.sql`) that proves
  constraint behaviour with real violating inserts.
- ✅ Migration runner (`db/scripts/migrate.ps1`).
- ✅ Local PostgreSQL via `infra/docker-compose.yml`.
- ⏸️ **Migrations not yet executed against a live server** — PostgreSQL and
  Docker are both absent from this machine. Needs §3 or §2 of `SETUP.md`.

## Phase 3 — Authentication ⏸️ (partial: no external services needed yet)

- ⬜ Phone OTP (needs **Firebase**: Phone Auth enabled) ⏸️
- ⬜ Email OTP (needs **email provider decision + API key**) ⏸️
- ⬜ Google Sign-In (needs **Google OAuth client ID/secret + SHA-1**) ⏸️
- ⬜ Microsoft Sign-In (needs **Azure app ID/secret**) ⏸️
- ✅ Session / device / refresh-token schema already in place.

## Phase 4 — WebSocket & presence ⬜
Authenticated socket, typed+versioned events, heartbeat presence, auto-reconnect
on network change / resume / background transitions.

## Phase 5 — One-to-one messaging ⬜
Send/receive, idempotent retries, delivery + read receipts, typing, offline
queue with honest pending/sent/delivered/read states.

## Phase 6 — Media, voice messages ⏸️
Upload/download with progress and retry, the audio player (waveform, speed,
seek, cache). **Needs object-storage decision + keys.**

## Phase 7 — Firebase notifications ⏸️
FCM in foreground/background/terminated, incoming-call and message
notifications, deep-link routing. **Needs Firebase config + service account.**

## Phase 8 — WebRTC signalling ⬜
Offer/answer/ICE over the WebSocket; all call-state events.

## Phase 9 — Metered TURN 🔨 (server side done & live-verified)
- ✅ `TurnCredentialService` on the backend: fetches ICE servers from Metered,
  caches them, adds Google STUN, and fails loudly with actionable errors.
- ✅ `GET /api/v1/rtc/ice-servers` route (auth-gated in production).
- ✅ **Verified live**: 3 STUN + 4 TURN endpoints obtained from
  `athur.metered.live`. No secret ever reaches the client.
- ⬜ Client-side ICE usage lands with WebRTC in Phase 8/10.
- ⚠️ Rotate the API key (it was shared in chat).

## Phase 10 — Audio calling ⬜
Real audio calls, full audio routing (earpiece / speaker / Bluetooth / headset),
interruption handling.

## Phase 11 — Video calling ⬜
Camera switching, adaptive resolution/bitrate, network adaptation.

## Phase 12 — Call history, notifications & ringtone ⬜
Real call history from PostgreSQL, the custom-MP3 ringtone system for incoming
**and** outgoing calls, live diagnostics panel (real `getStats()` values only),
deterministic quality tiers, controlled ICE-restart recovery.

## Phase 13 — Groups & advanced messaging ⬜
Roles/permissions, invite links, pinned messages, mentions, forwarding, edits,
deletions, reactions, message search.

## Phase 14 — Privacy & security ⬜
Server-enforced privacy, rate limiting, brute-force protection, file validation,
reporting/moderation, device sessions, security-event notifications.

## Phase 15 — Stories, social feed, short videos, live ⬜
Stories with expiry/privacy/viewer; posts with comments/reactions/shares/saved;
vertical short-video feed; live broadcasting on a scalable streaming design.

## Phase 16 — Unique Athur features ⬜
Call health timeline, recovery score, personal communication dashboard,
per-contact communication controls, call mini-window, per-chat data usage,
call-quality history, storage manager, custom chat appearance, advanced
notification rules. **All deterministic — no AI.**

## Phase 17 — Self-hosted APK update system ⏸️
Signed APK, SHA-256 verification, mandatory/optional updates, in-app installer.
**Needs release keystore + release storage/host.**

## Phase 18 — CI/CD ⏸️
GitHub Actions: format, analyze, test, build, sign, hash, publish manifest.

## Phase 19 — Testing & hardening ⬜
Including the nine required WebRTC scenarios (Wi-Fi↔4G↔5G, network loss,
background/foreground, Bluetooth, incoming call while backgrounded).

## Phase 20 — Production quality gate ⬜
Full analyze/format/test matrix end to end before anything is called done.

---

## What I need from you to unblock the next phases

1. **PostgreSQL** — install it, or install Docker so `docker compose` works.
   *(Unblocks Phase 2 verification.)*
2. **Backend stack** — ✅ decided: Dart/Shelf.
3. **Email provider** for OTP — which one? *(Phase 3.)*
4. **Object storage** for media — S3 / R2 / MinIO? *(Phase 6.)*
5. **Firebase** config + service account *(Phase 7)*, **Metered** key *(Phase 9)*,
   **OAuth** client IDs/secrets *(Phase 3)*, **release keystore** *(Phase 17)*.

See `docs/CREDENTIALS.md` for the precise, per-item list.
