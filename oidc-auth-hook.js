"use strict";

/**
 * OpenID Connect sign-in for Unleash OSS, next to the built-in password login.
 *
 * Plugs in through Unleash's public `customAuthHandler` extension point and only
 * uses public API (`AuthenticationRequired`, `userService.loginUserSSO`,
 * `accessService.setUserRootRole`, the session Unleash already mounts). No
 * unleash-server code is copied or patched, so upstream upgrades stay a version
 * bump — scripts/smoke-test.sh exercises every one of these contracts.
 *
 * Access is granted by the identity provider, not by "being able to log in":
 * the ID token must carry one of the configured roles (highest wins), and the
 * user's Unleash root role is re-synced from it on every login.
 *
 * Configuration (all via environment, see README):
 *   UNLEASH_OIDC_ISSUER            issuer URL (discovery is used)
 *   UNLEASH_OIDC_CLIENT_ID         confidential client id
 *   UNLEASH_OIDC_CLIENT_SECRET     client secret
 *   UNLEASH_OIDC_IDP_HINT          optional, sent as `kc_idp_hint` (Keycloak brokering)
 *   UNLEASH_OIDC_ALLOWED_DOMAINS   optional, comma-separated email domains
 *   UNLEASH_OIDC_ROLES_CLAIM       claim path, default `resource_access.<client id>.roles`
 *   UNLEASH_OIDC_ADMIN_ROLE        default `unleash_admin`
 *   UNLEASH_OIDC_EDITOR_ROLE       default `unleash_editor`
 *   UNLEASH_OIDC_VIEWER_ROLE       default `unleash_viewer`
 *   UNLEASH_OIDC_BUTTON_TEXT       default `Sign in with single sign-on`
 *   UNLEASH_OIDC_ALLOW_INSECURE    `true` only for local tests against an http issuer
 *   UNLEASH_SOURCE_URL             optional, `GET /source` redirects here (AGPL §13 offer)
 */

const { AuthenticationRequired } = require("unleash-server");

const REQUIRED = ["UNLEASH_OIDC_ISSUER", "UNLEASH_OIDC_CLIENT_ID", "UNLEASH_OIDC_CLIENT_SECRET"];

function isConfigured(env = process.env) {
  return REQUIRED.every((name) => Boolean(env[name]));
}

function readSettings(env = process.env) {
  const clientId = env.UNLEASH_OIDC_CLIENT_ID;
  return {
    issuer: env.UNLEASH_OIDC_ISSUER,
    clientId,
    clientSecret: env.UNLEASH_OIDC_CLIENT_SECRET,
    idpHint: env.UNLEASH_OIDC_IDP_HINT || "",
    allowedDomains: (env.UNLEASH_OIDC_ALLOWED_DOMAINS || "")
      .split(",")
      .map((d) => d.trim().toLowerCase())
      .filter(Boolean),
    rolesClaim: env.UNLEASH_OIDC_ROLES_CLAIM || `resource_access.${clientId}.roles`,
    // Highest first: the first match decides the Unleash root role.
    roleMap: [
      [env.UNLEASH_OIDC_ADMIN_ROLE || "unleash_admin", "Admin"],
      [env.UNLEASH_OIDC_EDITOR_ROLE || "unleash_editor", "Editor"],
      [env.UNLEASH_OIDC_VIEWER_ROLE || "unleash_viewer", "Viewer"],
    ],
    buttonText: env.UNLEASH_OIDC_BUTTON_TEXT || "Sign in with single sign-on",
    allowInsecure: env.UNLEASH_OIDC_ALLOW_INSECURE === "true",
    sourceUrl: env.UNLEASH_SOURCE_URL || "",
  };
}

// `resource_access.unleash.roles` -> claims.resource_access.unleash.roles
function claimAt(claims, dottedPath) {
  return dottedPath.split(".").reduce((node, key) => (node == null ? undefined : node[key]), claims);
}

/**
 * Decide from verified ID-token claims whether the user may sign in, and as what.
 * Pure function, so the policy is testable without an identity provider.
 */
function authorize(claims, settings) {
  const email = typeof claims.email === "string" ? claims.email.toLowerCase() : "";
  if (!email) return { ok: false, reason: "Your account has no email address." };
  if (claims.email_verified !== true) {
    return { ok: false, reason: "Your email address is not verified." };
  }
  const domain = email.split("@")[1] || "";
  if (settings.allowedDomains.length > 0 && !settings.allowedDomains.includes(domain)) {
    return { ok: false, reason: "Your account is not allowed to use Unleash." };
  }
  const granted = claimAt(claims, settings.rolesClaim);
  const roles = Array.isArray(granted) ? granted : [];
  const match = settings.roleMap.find(([role]) => roles.includes(role));
  if (!match) return { ok: false, reason: "You have not been granted access to Unleash." };
  return { ok: true, email, name: claims.name || email, rootRole: match[1] };
}

function oidcAuthHook(app, config, services) {
  const settings = readSettings();
  const base = config.server.baseUriPath || "";
  const unleashUrl = config.server.unleashUrl.replace(/\/$/, "");
  const redirectUri = `${unleashUrl}${base}/api/auth/callback`;
  const logger = config.getLogger("oidc-auth-hook.js");
  const { userService, accessService } = services;

  // openid-client is ESM-only; load it and run discovery once, lazily.
  let clientPromise;
  const getClient = () => {
    if (!clientPromise) {
      clientPromise = (async () => {
        const client = await import("openid-client");
        const options = settings.allowInsecure ? { execute: [client.allowInsecureRequests] } : undefined;
        const configuration = await client.discovery(
          new URL(settings.issuer),
          settings.clientId,
          settings.clientSecret,
          undefined,
          options,
        );
        return { client, configuration };
      })().catch((error) => {
        clientPromise = undefined; // retry discovery on the next login
        throw error;
      });
    }
    return clientPromise;
  };

  const loginFailed = (res, message) =>
    res.redirect(`${base}/login?errorMsg=${encodeURIComponent(message)}`);

  if (settings.sourceUrl) {
    app.get(`${base}/source`, (req, res) => res.redirect(settings.sourceUrl));
  }

  app.get(`${base}/auth/oidc/login`, async (req, res) => {
    try {
      const { client, configuration } = await getClient();
      const codeVerifier = client.randomPKCECodeVerifier();
      const state = client.randomState();
      const nonce = client.randomNonce();
      req.session.oidc = { codeVerifier, state, nonce };
      const params = {
        redirect_uri: redirectUri,
        scope: "openid email profile",
        code_challenge: await client.calculatePKCECodeChallenge(codeVerifier),
        code_challenge_method: "S256",
        state,
        nonce,
      };
      if (settings.idpHint) params.kc_idp_hint = settings.idpHint;
      res.redirect(client.buildAuthorizationUrl(configuration, params).href);
    } catch (error) {
      logger.error("OIDC login could not start", error);
      loginFailed(res, "Single sign-on is unavailable right now. Use your password or try again later.");
    }
  });

  // Registered before the /api guard below, so the callback itself needs no session.
  app.get(`${base}/api/auth/callback`, async (req, res) => {
    const pending = req.session.oidc;
    delete req.session.oidc;
    if (!pending) return loginFailed(res, "Your sign-in expired. Please try again.");
    try {
      const { client, configuration } = await getClient();
      const currentUrl = new URL(`${unleashUrl}${req.originalUrl}`);
      const tokens = await client.authorizationCodeGrant(configuration, currentUrl, {
        pkceCodeVerifier: pending.codeVerifier,
        expectedState: pending.state,
        expectedNonce: pending.nonce,
        idTokenExpected: true,
      });
      const decision = authorize(tokens.claims(), settings);
      if (!decision.ok) {
        logger.warn(`OIDC login refused: ${decision.reason}`);
        return loginFailed(res, decision.reason);
      }
      const user = await userService.loginUserSSO({
        email: decision.email,
        name: decision.name,
        rootRole: decision.rootRole,
        autoCreate: true,
      });
      // loginUserSSO only applies rootRole when it creates the user; re-sync it on
      // every login so a group change at the identity provider takes effect.
      await accessService.setUserRootRole(user.id, decision.rootRole);
      req.session.regenerate((error) => {
        if (error) {
          logger.error("Could not start a session after OIDC login", error);
          return loginFailed(res, "Sign-in failed. Please try again.");
        }
        req.session.user = user;
        res.redirect(`${base}/`);
      });
    } catch (error) {
      logger.error("OIDC callback failed", error);
      loginFailed(res, "Sign-in failed. Please try again.");
    }
  });

  // Same contract as Unleash's own password-mode authorization middleware, plus an
  // SSO option: the stock login page then shows the password form and an SSO button.
  const guard = (req, res, next) => {
    if (!req.user?.isAPI && req.session?.user) {
      req.user = req.session.user;
      return next();
    }
    if (req.user) return next(); // API and personal access tokens, set by Unleash earlier
    if (req.header("authorization")) {
      return res.status(401).json({ message: "You must log in to use Unleash." });
    }
    const error = new AuthenticationRequired({
      type: "password",
      path: `${base}/auth/simple/login`,
      message: "You must log in to use Unleash.",
      options: [{ type: "oidc", message: settings.buttonText, path: `${base}/auth/oidc/login` }],
    });
    return res.status(error.statusCode).json(error);
  };
  app.use(`${base}/api`, guard);
  app.use(`${base}/logout`, guard);
}

module.exports = oidcAuthHook;
module.exports.isConfigured = isConfigured;
module.exports.readSettings = readSettings;
module.exports.authorize = authorize;
