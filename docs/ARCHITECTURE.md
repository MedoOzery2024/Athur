# Athur — Architecture

> Athur is a **real** human-to-human communication platform: audio/video calls,
> messaging, and social sharing. It contains **no AI features** by design.

## 1. Repository layout

```
D:\Athur\
├── app/           Flutter client (Android, iOS, Windows)
├── server/        Dart/Shelf backend: REST + WebSocket + integrations
├── db/            PostgreSQL migrations + verification scripts
├── infra/         Local dev infra (docker compose), CI, release tooling
├── docs/          Architecture, configuration, roadmap, credential checklist
└── assets_src/    Original logo + ringtone (source of truth copies)
```

**Why a monorepo with one language:** both the client and the server are Dart.
That means shared model shapes, one toolchain, and no cross-language drift — a
concrete reliability win over a mixed stack.

## 2. High-level data flow

```
Flutter app  ──HTTP/JSON──▶  Athur backend  ──SQL──▶  PostgreSQL
     │                            │
     └──────WebSocket────────────▶│──▶ Firebase (FCM / Phone Auth)
                                  │──▶ Metered (TURN credential minting)
                                  │──▶ Object storage (media metadata only)
                                  └──▶ WebRTC signalling relay
```

**Hard rule:** the Flutter app **never** connects to PostgreSQL directly. Every
read and write goes through the backend, which owns authentication,
authorisation and validation.

## 3. Client architecture (`app/`)

Layered, feature-first:

```
lib/
├── main.dart                 entry point (minimal, fast boot)
├── app/
│   └── app.dart              root widget, theme, stage routing
├── core/                     cross-cutting concerns
│   ├── theme/                colours, typography, tokens, ThemeData
│   ├── config/               bootstrap, environment config
│   ├── constants/            asset paths, app metadata
│   ├── errors/               error types and mapping
│   ├── utils/                pure helpers
│   └── widgets/              shared UI (logo, scrollbar, empty state)
└── features/                 one folder per feature
    └── <feature>/
        ├── presentation/     screens + widgets
        ├── state/            state holders (added per phase)
        ├── domain/           entities + use cases (added per phase)
        └── data/             repositories + datasources (added per phase)
```

Current features: `splash`, `home`, `chats`, `calls`, `contacts`, `settings`.

**Design-system notes**
- Dark-only theme. Black surfaces, gold (`#D4AF37`) accent.
- All colours/spacings/radii/durations are tokens in `core/theme/` — no widget
  hardcodes a hex value or a magic number.
- `AthurScrollbar` wraps scrollables so the global-scrollbar requirement is met
  consistently and accessibly.
- Brand assets are wrapped by `AthurLogo` / `AthurBrandLockup`, so the logo is
  never redrawn or recoloured.

## 4. Backend architecture (`server/`)

```
server/
├── bin/server.dart           entry point: config → DB → serve → graceful stop
└── lib/
    ├── athur_server.dart     public barrel
    └── src/
        ├── config/           environment-driven configuration
        ├── core/errors/      stable API error contract
        ├── api/
        │   ├── server.dart   middleware pipeline + route mounting
        │   ├── json.dart     JSON request/response helpers
        │   ├── middleware/   error handler, logging, hardening headers
        │   └── routes/       health, version (more per phase)
        └── data/             PostgreSQL pool + query helpers
```

**Middleware order** (outermost first) — order is load-bearing:
1. `errorHandler` — nothing escapes unstructured.
2. request logger — method, path, status, duration.
3. `jsonHeaders` — guarantees a JSON content type.
4. security headers — `nosniff`, `DENY`, `no-referrer`.

**Error contract** — every failure returns the same shape, and internal detail
is logged server-side, never returned:
```json
{ "error": { "code": "NOT_FOUND", "message": "Chat not found" } }
```

## 5. Database architecture (`db/`)

PostgreSQL is the single source of truth. Migrations are numbered and each
records itself in `schema_migrations`, so runs are idempotent.

| Migration | Domain |
|---|---|
| `0001` | extensions, migration ledger, `set_updated_at()` trigger |
| `0002` | identity & auth (users, identities, devices, sessions, OTP, security events) |
| `0003` | social graph, privacy, notification & user settings |
| `0004` | messaging core (chats, members, messages, receipts, folders) |
| `0005` | groups, media, presence, typing |
| `0006` | calls, call events/quality/summary, push tokens, notifications, reports |
| `0007` | social posts/comments, stories, live, saved, hashtags, releases, audit |

**Conventions**
- UUID primary keys (`gen_random_uuid()`) — never serial ints.
- `timestamptz` everywhere; `updated_at` maintained by trigger.
- Soft delete via `deleted_at` where history must stay coherent.
- Explicit, intentional foreign keys with deliberate `ON DELETE` actions.
- Binaries never stored in PostgreSQL: only storage keys + metadata.

**Notable correctness guards**
- `auth_identities (provider, provider_uid)` is unique → one external identity
  maps to exactly one account, which is what makes account linking safe.
- `chats.direct_key` unique → exactly one 1:1 conversation per user pair.
- `messages (chat_id, sender_id, client_message_id)` unique → **idempotent
  sends**, so a network retry cannot duplicate a message.
- `message_delivery_status` is per recipient → group read state is correct.
- `app_releases (platform, version_code)` unique → a versionCode can never be
  published twice.

## 6. Realtime, calls, notifications (planned per phase)

- **WebSocket**: authenticated, typed, versioned events; auto-reconnect with
  backoff on network change, resume, and background/foreground transitions.
- **Presence**: heartbeat + connection state, never a stale boolean.
- **WebRTC**: Google STUN + Metered TURN; TURN credentials minted server-side
  and short-lived; controlled ICE restart with backoff; real `getStats()`
  diagnostics only.
- **Notifications**: FCM for foreground/background/terminated, with deep links.

## 7. Testing strategy

- Client: `flutter analyze` + widget/unit tests (`app/test/`).
- Server: `dart analyze` + unit tests with an injected fake database
  (`server/test/`) — no real DB needed to verify routing and the error contract.
- Database: `db/scripts/schema_test.sql` proves constraint behaviour by
  attempting real violating inserts inside a rolled-back transaction.
