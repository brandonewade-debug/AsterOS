# AsterOS Companion — development build

Companion container for AsterOS, not an Unraid replacement. Implements one-time device pairing, token revocation, scoped folder listing/creation/download, resumable chunked uploads, SHA-256 verification and no-overwrite completion. No photo indexing, QR rendering, tunnel, proxy, Docker socket, host control or telemetry.

## Unraid installation

Create dedicated folders `/mnt/user/appdata/asteros-companion` and `/mnt/user/AsterOS` and give UID 99/GID 100 access to those newly created folders only. Build from this directory and use the Compose file or equivalent Docker options. The default bind address is localhost. Expose it through a trusted HTTPS reverse proxy; do not forward this HTTP service directly through your router. Alternatively bind only a private LAN/VPN address for development and use an HTTPS proxy for the iOS client.

The container runs as 99:100, with a read-only root filesystem, no extra capabilities and no Docker socket. Existing media shares are not mounted. `/data` holds hashed device tokens, the SQLite database and resumable upload staging. `/storage` is the dedicated files area. Persistent state and files survive container replacement; never remove these volumes during an update.

Generate a single-use pairing code (expires after five minutes):

```sh
docker exec asteros-companion python -m companion.admin pair
```

Pair via `POST /v1/pair` with JSON `{ "code": "CODE_FROM_COMMAND", "name": "My iPhone" }`. Store the returned bearer token securely. Use `Authorization: Bearer TOKEN` on all `/v1` routes except pairing. No token is returned by listing/status endpoints. Generate codes locally; none appear in container startup logs.

List and revoke devices:

```sh
docker exec asteros-companion python -m companion.admin devices
docker exec asteros-companion python -m companion.admin revoke DEVICE_ID
```

## HTTP API v1

- `GET /health`: unauthenticated service/version health only.
- `GET /v1/status`: capabilities and free space.
- `GET /v1/files?path=`: root listing, or relative subfolder.
- `POST /v1/folders`: JSON `path` (parent must exist).
- `GET /v1/file?path=...`: file stream.
- `POST /v1/uploads`: JSON `path`, `size`, `sha256`; returns task ID and offset.
- `PUT /v1/uploads/{id}?offset=N`: raw bytes, maximum 4 MiB.
- `GET /v1/uploads/{id}`: authoritative offset for reconnect/resume.
- `POST /v1/uploads/{id}/complete`: empty body with Content-Length 0; verifies checksum and creates destination without overwrite.
- `DELETE /v1/uploads/{id}`: cancel incomplete task; never deletes a completed destination.
- `DELETE /v1/device`: revoke the current device.

Paths reject traversal and symlinks, and descriptor-relative file access avoids path substitution between validation and use. Only regular files and directories are exposed. All paired devices share the dedicated storage scope; individual folder permissions are not implemented. Upload ownership is per device. Eight simultaneous incomplete transfers maximum; default 10 GiB per file and a 1 GiB free-space reserve. Staging plus final-copy space is reserved conservatively. Incomplete tasks persist until completed or cancelled. No range downloads or server-side media previews yet.

A reverse proxy should enforce body/time limits, use TLS and avoid logging authorization headers. Only one worker is configured. Local server administrators remain trusted. A full security review is still required before commercial distribution.

## Tests

From this directory, install requirements plus pytest/httpx in a virtual environment, then run `python -m pytest -q`. Tests cover authentication, pairing replay/expiry, path traversal, symlinks, chunk recovery across restart, checksum mismatch, cancellation, no-overwrite behavior, device isolation and free-space bounds.
