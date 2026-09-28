# unleash-oss-extensions

A small layer on top of [Unleash OSS](https://github.com/Unleash/unleash) (`unleash-server` from npm) that adds two things through Unleash's **public extension points**, without copying or patching any Unleash code:

1. **Custom flag environments** (for example `testing` and `staging` next to `development` and `production`).
2. **OpenID Connect sign-in** next to the built-in password login, with access and root role taken from the identity provider.

Not affiliated with or endorsed by Unleash AS. Unleash is a trademark of its owners.

## Why

Unleash OSS restricts environments to `default`, `development` and `production`, and ships no single sign-on. Community examples of SSO hooks exist, but they give every successful login an account (often Editor or Admin). This layer grants access only when the ID token carries a configured role, re-syncs the Unleash root role at every login, and keeps password login and API tokens working.

## How it works

- **Environments** — `index.js` starts Unleash with `ui: { environment: "pro" }`. `resolveIsOss()` in unleash-server's `create-config.ts` then stops filtering environments to the OSS defaults; `isEnterprise` stays false, and no enterprise code is involved (none exists in the OSS package). The environments themselves are rows in the database: see `sql/01-environments.sql` (run once, idempotent).
- **Sign-in** — `oidc-auth-hook.js` is a `customAuthHandler`. It uses the [`openid-client`](https://github.com/panva/openid-client) library (authorization code flow with PKCE, state and nonce), then Unleash's own `userService.loginUserSSO` and `accessService.setUserRootRole`. Unauthenticated users get Unleash's stock login page with the password form **and** an SSO button.

```
Browser -> /auth/oidc/login -> identity provider -> /api/auth/callback
        -> verify ID token -> check role, email domain, email_verified
        -> loginUserSSO + setUserRootRole -> session
```

Refused (and no account created): no configured role, an email domain outside the allow-list, or an unverified email.

## Configuration

SSO switches on when issuer, client id and secret are all set; otherwise Unleash runs with its stock password auth.

| Variable | Meaning | Default |
|---|---|---|
| `UNLEASH_URL` | Public URL of Unleash (used for the redirect URI) | *(required by Unleash)* |
| `UNLEASH_OIDC_ISSUER` | Issuer URL (discovery is used) | — |
| `UNLEASH_OIDC_CLIENT_ID` | Confidential client id | — |
| `UNLEASH_OIDC_CLIENT_SECRET` | Client secret | — |
| `UNLEASH_OIDC_IDP_HINT` | Sent as `kc_idp_hint` (Keycloak identity brokering) | *(none)* |
| `UNLEASH_OIDC_ALLOWED_DOMAINS` | Comma-separated email domains | *(any)* |
| `UNLEASH_OIDC_ROLES_CLAIM` | Dotted claim path holding the roles | `resource_access.<client id>.roles` |
| `UNLEASH_OIDC_ADMIN_ROLE` / `_EDITOR_ROLE` / `_VIEWER_ROLE` | Role names mapped to Unleash root roles (highest wins) | `unleash_admin` / `unleash_editor` / `unleash_viewer` |
| `UNLEASH_OIDC_BUTTON_TEXT` | Label of the SSO button | `Sign in with single sign-on` |
| `UNLEASH_OIDC_ALLOW_INSECURE` | `true` allows an `http://` issuer — tests only | `false` |
| `UNLEASH_SOURCE_URL` | `GET /source` redirects here (AGPL-3.0 §13 source offer) | *(off)* |

Register the redirect URI `<UNLEASH_URL>/api/auth/callback` with your identity provider, and make sure the roles are in the **ID token**. With Keycloak: client roles on the client, a *User Client Role* mapper with "Add to ID token", and groups carrying the roles.

## Build and test

```bash
docker build -t unleash-oss-extensions .
scripts/smoke-test.sh                                   # fresh database
scripts/smoke-test.sh --upgrade-from <older image>      # upgrade path
```

The smoke test needs only Docker. It runs Postgres, the image and a Keycloak (`test/keycloak-realm.json`) and checks: custom environments are visible; backend tokens scoped to them work; admin and editor sign in with the matching root role; users without a role, with the wrong domain or an unverified email are refused without an account; a group change at the identity provider changes the Unleash role at the next login; password login and API tokens keep working. It fails if a new unleash-server release changes any extension point this layer relies on — run it on every version bump.

## Upgrading unleash-server

Pin the exact version in `package.json` (`version` and the `unleash-server` dependency), regenerate the lock file, follow upstream's Node version in the `Dockerfile`, and run both smoke tests.

## License

[AGPL-3.0-or-later](LICENSE), the license of unleash-server 8.x.
