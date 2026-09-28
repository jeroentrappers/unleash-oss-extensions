"use strict";

const unleash = require("unleash-server");

const options = {
  // `ui.environment` drives `resolveIsOss()` in unleash-server's
  // create-config.ts: `isOss = !isEnterprise && uiEnvironment !== 'pro'`
  // (case-insensitive). Setting it to "pro" lifts the hard-coded OSS
  // allowlist on environments (['default', 'development', 'production'])
  // and projects, while `isEnterprise` stays false — no enterprise code
  // exists in the OSS package. This is what makes our custom
  // testing/staging environments (provisioned via sql/) visible to the
  // Admin UI and SDK APIs.
  //
  // Verify on every unleash-server upgrade that `resolveIsOss()` still
  // behaves this way before bumping the dependency (see README).
  ui: {
    environment: "pro",
  },
};

// OpenID Connect sign-in next to the password login — only wired up when the
// issuer, client id and secret are all set (see oidc-auth-hook.js). Without them
// the image runs Unleash's stock password auth, e.g. for local development or as
// an emergency fallback by unsetting the variables.
const oidcAuthHook = require("./oidc-auth-hook");
if (oidcAuthHook.isConfigured()) {
  options.authentication = {
    type: "custom",
    customAuthHandler: oidcAuthHook,
  };
}

unleash.start(options);
