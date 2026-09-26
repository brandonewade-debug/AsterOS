# AsterOS connection paths

## Direct Unraid access

Use the server's HTTPS WebGUI base URL, with its actual HTTPS port. A local or VPN-reachable URL avoids website authentication middleware. Certificates must be valid; the app does not disable TLS verification or forward API keys across redirects.

The connection screen supports either a manually supplied key or the official Unraid `ApiKeyAuthorize` flow. The setup screen offers Viewer access or Manage Docker. Manage Docker is selected for this owner-focused test build and requests `role:viewer` plus `docker:read`, `docker:create`, `docker:update`, and `docker:delete`. Turn it off to request only `role:viewer`. Unraid displays the requested access for approval.

The in-app authorization browser uses an ephemeral session. Its HTTPS callback is an unpredictable path on the selected server; it is intercepted before a network request. Callback origin, port, path, state, age, and parameter uniqueness are validated. The returned key is tested against the API and stored in this device's Keychain only if the connection succeeds. Password fields and browser cookies are not read by the app. An external identity provider may reject embedded browsers; the Safari alternative omits the automatic callback and requires copying the generated key back into the app.

A browser login does not automatically authenticate the separate native URLSession. Cloudflare Access and Organizr protections therefore need their own integration or a different network path. The app does not claim that approving an Unraid key bypasses those protections.

## Diagnosed deployment

The development server's public `/graphql` request is intercepted by Nginx's Organizr `auth_request` rule. An unauthenticated response is converted into a 302 redirect to the site's login homepage. Cloudflare Access is another protection layer. The directly reachable LAN HTTPS URL returns the GraphQL authentication response with a valid certificate, confirming that the API itself is reachable. No public access policy was weakened during diagnosis.

## Companion gateway direction

The existing companion authenticates paired devices for its file API. It does not yet proxy the Unraid dashboard or Docker controls.

The intended extension is a paired gateway:

1. The owner pairs AsterOS using a short-lived, single-use code (eventually a QR code).
2. Each device receives its own revocable credential, stored in Keychain. The companion stores its hash.
3. The companion uses an owner-authorized, narrowly scoped Unraid credential locally.
4. Only explicit dashboard and Docker operations are exposed, rather than a general-purpose proxy.
5. Remote access uses a dedicated HTTPS domain/tunnel or private VPN path. The public Unraid website keeps its existing authentication rules.

A URL alone is not a credential and cannot guarantee that only the official app can reach it. Paired-device authorization must protect every sensitive endpoint. Device revocation, rate limits, replay/expiry handling, and explicit permissions remain requirements. Public hostname provisioning and Cloudflare configuration are separate from running a Docker image.

## References

- https://docs.unraid.net/API/api-key-app-developer-authorization-flow/
- https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/
