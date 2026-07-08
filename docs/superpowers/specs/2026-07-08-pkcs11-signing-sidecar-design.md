---
title: PKCS#11 Signing Sidecar for Forgejo
date: 2026-07-08
status: design
---

# PKCS#11 Signing Sidecar for Forgejo

Two container images that together let a Forgejo pod sign git commits and tags using a PKCS#11 token (e.g. Infisical Signers) without baking any provider into the signing daemon.

## Goals

- A sidecar image that runs `gnupg-pkcs11-scd` so Forgejo (via a user-provided `scdaemon-program` shim) can sign commits and tags.
- An interchangeable provider image pattern: the Infisical PKCS#11 module is shipped as the first instance, but YubiHSM, OpenSC, softhsm, etc. can be added later with the same shape.
- Providers are NOT baked into the sidecar. The user wires them in at runtime by mounting one or more provider images into a well-known directory.
- Configuration of the daemon is generated from environment variables; the user does not have to mount a hand-written `gnupg-pkcs11-scd.conf`.

## Non-Goals

- The shim binary that bridges `gpg-agent`'s `scdaemon-program` to the sidecar's unix socket. That lives in the user's Forgejo pod and is outside the scope of these images.
- Forgejo deployment manifests, Compose files, or Helm charts. A short README example is included as documentation only; production wiring is the user's responsibility.
- Building or signing Forgejo's own artifacts. The use case is signing user activity (commits, tags) performed via Forgejo's web UI or API, where `git commit -S` runs inside the Forgejo container.

## Architecture

```
forgejo pod
+-----------------------------+       +--------------------------------+
|  forgejo container          |       | gnupg-pkcs11-scd sidecar       |
|                             |       |                                |
|  gpg-agent ---stdin/stdout--+--shim-+--- unix socket -->             |
|   ^                         |       |   gnupg-pkcs11-scd --daemon    |
|   | scdaemon-program: shim  |       |   providers: /providers/*/     |
|                             |       |     lib<name>*.so              |
|  git commit -S --(GPG)-->   |       |                                |
+-----------------------------+       +--------------------------------+
                ^                                       ^
                +--- shared emptyDir /var/run/gnupg-pkcs11-scd --+
                                                          ^
                                                          |
                                          mounted from provider image
                                          (image root bind-mounted
                                          to /providers/<name>/)
```

- `gnupg-pkcs11-scd` is a `scdaemon-program`; it speaks the assuan protocol over a local unix socket.
- Forgejo's `gpg-agent` runs in the same pod. Its `scdaemon-program` points at a user-supplied shim that opens the shared socket and forwards stdio.
- The provider image contributes only the `.so` file at its filesystem root. The user binds its `/` directory to `/providers/<name>/` in the sidecar; the sidecar finds the library by globbing `lib<name>*.so`.

## Components

### Image 1 — `apps/gnupg-pkcs11-scd/`

| File | Purpose |
|---|---|
| `Dockerfile` | Single-stage `debian:bookworm-slim`; installs pinned `gnupg-pkcs11-scd`; copies entrypoint; declares volumes. |
| `entrypoint.sh` | Generates the daemon config from env vars; `exec`s the daemon. |
| `metadata.yaml` | One `stable` channel, `linux/amd64` + `linux/arm64`, `tests.enabled: true, type: cli`. |
| `ci/latest.sh` | Reports the Debian bookworm `gnupg-pkcs11-scd` version for CI drift display. |
| `ci/goss.yaml` | Asserts binary, dirs, and the entrypoint script. |

### Image 2 — `apps/infisical-pkcs11-provider/`

| File | Purpose |
|---|---|
| `Dockerfile` | `FROM scratch`; upstream tarball extracted to a single file at root. |
| `metadata.yaml` | One `stable` channel, `linux/amd64` + `linux/arm64`, `tests.enabled: true, type: cli`. |
| `ci/latest.sh` | GitHub releases API for `Infisical/infisical-pkcs-11`; strips `v` prefix. |
| `ci/goss.yaml` | Asserts `/libinfisical-pkcs11.so` exists and is a regular file. |

## Image 1 — `gnupg-pkcs11-scd` detail

### Dockerfile

Single stage, Debian 12 (bookworm) to match the rest of this repo's apps:

```dockerfile
FROM mirror.gcr.io/debian:bookworm-slim
ARG VERSION=0.10.0-2

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      gnupg-pkcs11-scd=${VERSION} \
      ca-certificates \
      bash \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN mkdir -p /var/run/gnupg-pkcs11-scd \
             /var/lib/gnupg-pkcs11-scd \
 && chown 1000:1000 /var/lib/gnupg-pkcs11-scd \
 && chmod 1777 /var/run/gnupg-pkcs11-scd

VOLUME ["/var/run/gnupg-pkcs11-scd"]

USER 1000:1000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

HEALTHCHECK CMD sh -c 'for f in /var/run/gnupg-pkcs11-scd/gnupg-pkcs11-scd.*/agent.S; do [ -S "$f" ] && exit 0; done; exit 1'
```

### Entrypoint contract (`entrypoint.sh`)

The daemon (`gnupg-pkcs11-scd`) has hardcoded expectations:

- **Config path** is fixed to `${GNUPGHOME}/gnupg-pkcs11-scd.conf` (no `--config` flag).
- **Socket path** is fixed to `${GNUPG_PKCS11_SOCKETDIR}/gnupg-pkcs11-scd.XXXXXX/agent.S` where `XXXXXX` is a `mkdtemp(3)` random suffix (no `--socket` flag).
- **`--homedir`** overrides `GNUPGHOME`.
- **`--multi-server`** runs the daemon foreground with both a unix-socket accept thread AND a foreground pipe handler on stdin/stdout. The pipe handler exits on stdin EOF.
- **`--daemon`** forks: parent prints `SCDAEMON_INFO=<socket>:<pid>:<n>; export SCDAEMON_INFO` and exits; child (with `--no-detach`) skips `setsid()`/`close(0/1/2)` and continues serving the unix socket. The parent exiting is a problem when the daemon is PID 1 in a container (the container terminates).

The entrypoint uses **`--daemon --no-detach` in a wrapper script** that runs the daemon in the background, parses `SCDAEMON_INFO` to discover the worker PID, and keeps PID 1 alive by polling `kill -0` on the worker. When the daemon dies, the poll loop exits and the container restarts. `SIGTERM`/`SIGINT`/`SIGHUP` are trapped and forwarded to the worker so `docker stop` / pod termination signals it cleanly.

The entrypoint script:

0. **Ensure runtime paths exist.** Run `mkdir -p` on `${SCD_HOMEDIR}` and `${SCD_SOCKET_DIR}` before any writes. The Dockerfile creates these paths at build time and chowns `/var/lib/gnupg-pkcs11-scd` to UID 1000, so this is normally a no-op. The defensive `mkdir -p` covers the case where the user mounts `SCD_HOMEDIR` or `SCD_SOCKET_DIR` to a path that does not yet exist (e.g. an emptyDir from a fresh k8s pod). If `mkdir` fails, exit 1 with a message that includes the path and the running UID.

1. **Determine the provider list.**

The entrypoint script:

0. **Ensure runtime paths exist.** Run `mkdir -p` on `${SCD_HOMEDIR}` and `${SCD_SOCKET_DIR}` before any writes. The Dockerfile creates these paths at build time and chowns `/var/lib/gnupg-pkcs11-scd` to UID 1000, so this is normally a no-op. The defensive `mkdir -p` covers the case where the user mounts `SCD_HOMEDIR` or `SCD_SOCKET_DIR` to a path that does not yet exist (e.g. an emptyDir from a fresh k8s pod). If `mkdir` fails, exit 1 with a message that includes the path and the running UID.

1. **Determine the provider list.**
   - If `PKCS11_PROVIDERS` is **set** (even to the empty string) → split on `,`, trim whitespace, drop empties. The empty-string case is treated as an explicit request for no providers and is rejected by step 2.
   - If `PKCS11_PROVIDERS` is **unset** → enumerate subdirectories of `${PKCS11_PROVIDER_DIR:-/providers}`. Each subdir's basename becomes a provider name. Subdirs whose `lib<name>*.so` glob finds zero matches are silently skipped (stray dirs).
2. **Validate the list is non-empty.** If empty → print a clear error and exit 1.
3. **For each provider name `<name>`** resolve the library path:
   - Check `PKCS11_PROVIDER_<UPPER_NAME>_LIBRARY` (uppercased name, non-alphanumerics replaced by `_`). If set AND the file exists → use it as-is.
   - Otherwise glob `${PKCS11_PROVIDER_DIR:-/providers}/<name>/lib<name>*.so`:
     - Exactly one match → use it.
     - Zero matches → if the name came from the explicit `PKCS11_PROVIDERS` list, fail-fast with the searched path; if it came from auto-enumeration, skip silently.
     - Multiple matches → fail-fast listing the matches and telling the user to set `PKCS11_PROVIDER_<NAME>_LIBRARY`.
4. **Write `${SCD_HOMEDIR}/gnupg-pkcs11-scd.conf`** with the resolved providers + paths.
5. **`exec` the daemon** with `GNUPG_PKCS11_SOCKETDIR` exported. With a TTY, just `exec gnupg-pkcs11-scd --multi-server`. In containers (no TTY), the script uses `--daemon --no-detach` in a backgrounded wrapper so PID 1 stays alive while the daemon (the fork's child) serves the unix socket. The wrapper polls the worker PID with `kill -0` and traps signals to forward them.

### Environment variables

| Var | Default | Behavior |
|---|---|---|
| `PKCS11_PROVIDERS` | *(unset → auto-enumerate)* | Comma-separated names. Set explicitly to override auto-enum. Setting to an empty string disables auto-enum and produces a no-providers error. |
| `PKCS11_PROVIDER_DIR` | `/providers` | Root for glob and enumeration. |
| `PKCS11_PROVIDER_<NAME>_LIBRARY` | — | Full path to `.so`. Overrides glob for that provider. `<NAME>` is uppercased name with non-alphanumerics replaced by `_`. |
| `INFISICAL_*` | — | Pass-through env read by the Infisical library when loaded. Set on the scd container. |
| `SCD_HOMEDIR` | `/var/lib/gnupg-pkcs11-scd` | Daemon homedir. The entrypoint writes the generated `gnupg-pkcs11-scd.conf` here. |
| `SCD_SOCKET_DIR` | `/var/run/gnupg-pkcs11-scd` | Daemon creates `${SCD_SOCKET_DIR}/gnupg-pkcs11-scd.XXXXXX/agent.S`. This directory is `VOLUME`-mounted so consumers can find the socket. |

### Entrypoint script

`apps/gnupg-pkcs11-scd/entrypoint.sh`:

```sh
#!/usr/bin/env bash
set -eu

PROVIDER_DIR="${PKCS11_PROVIDER_DIR:-/providers}"
SCD_HOMEDIR="${SCD_HOMEDIR:-/var/lib/gnupg-pkcs11-scd}"
SCD_SOCKET_DIR="${SCD_SOCKET_DIR:-/var/run/gnupg-pkcs11-scd}"
CONF="${SCD_HOMEDIR}/gnupg-pkcs11-scd.conf"

# --- Step 1: determine provider list ---
if [ "${PKCS11_PROVIDERS+set}" = set ]; then
  IFS=',' read -r -a raw <<<"$PKCS11_PROVIDERS"
else
  raw=()
  if [ -d "$PROVIDER_DIR" ]; then
    for d in "$PROVIDER_DIR"/*; do
      [ -d "$d" ] || continue
      raw+=("$(basename "$d")")
    done
  fi
fi

providers=()
for n in "${raw[@]}"; do
  n="${n// /}"
  [ -n "$n" ] && providers+=("$n")
done

if [ "${#providers[@]}" -eq 0 ]; then
  echo "PKCS11_PROVIDERS is empty and no provider directories found under $PROVIDER_DIR." >&2
  echo "Mount at least one provider image at $PROVIDER_DIR/<name>/, or set PKCS11_PROVIDERS explicitly." >&2
  exit 1
fi

explicit_set() { [ "${PKCS11_PROVIDERS+set}" = set ]; }

# --- Step 2: resolve library path per provider ---
lines=()
resolved_names=()
for name in "${providers[@]}"; do
  upper=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c '[:alnum:]' '_')
  override_var="PKCS11_PROVIDER_${upper}_LIBRARY"
  override="${!override_var:-}"

  if [ -n "$override" ] && [ -f "$override" ]; then
    lib="$override"
  else
    shopt -s nullglob
    matches=( "$PROVIDER_DIR/$name"/lib"${name}"*.so )
    shopt -u nullglob
    case "${#matches[@]}" in
      1) lib="${matches[0]}" ;;
      0)
        if explicit_set; then
          echo "No lib${name}*.so found at $PROVIDER_DIR/$name/ (and \$$override_var not set or invalid)." >&2
          exit 1
        else
          continue
        fi
        ;;
      *)
        echo "Multiple .so files found for provider '$name' under $PROVIDER_DIR/$name/:" >&2
        printf '  %s\n' "${matches[@]}" >&2
        echo "Set $override_var to disambiguate." >&2
        exit 1
        ;;
    esac
  fi

  lines+=( "" "# provider: $name" "provider-${name}-library ${lib}" )
  resolved_names+=("$name")
done

if [ "${#resolved_names[@]}" -eq 0 ]; then
  echo "No providers resolved after library lookup." >&2
  exit 1
fi

# --- Step 3: write config ---
{
  echo "# Generated by entrypoint.sh — do not edit by hand."
  printf 'providers %s\n' "$(IFS=,; echo "${resolved_names[*]}")"
  printf '%s\n' "${lines[@]}"
} > "$CONF"

# --- Step 4: exec daemon ---
# Do not `unset` provider-specific env vars here — INFISICAL_* and similar
# variables must propagate to the dlopened PKCS#11 library. The library
# reads them at load time via getenv(3).
#
# Run mode selection:
#   - TTY attached (`[ -t 0 ]`): interactive shell → `--multi-server`,
#     which speaks assuan on stdin/stdout.
#   - No TTY (container PID 1): use `--daemon --no-detach` in a wrapper.
#     `--daemon` mode forks; the parent prints SCDAEMON_INFO and exits,
#     which would terminate the container if the daemon were PID 1. We
#     run the daemon in the background, parse SCDAEMON_INFO for the
#     worker PID, then keep PID 1 alive by polling `kill -0` on the
#     worker. Signals (TERM/INT/HUP) are trapped and forwarded.
export GNUPG_PKCS11_SOCKETDIR="$SCD_SOCKET_DIR"
if [ -t 0 ]; then
  exec gnupg-pkcs11-scd --multi-server --homedir "$SCD_HOMEDIR"
fi

# Container path: background the daemon, parse SCDAEMON_INFO, poll the
# worker PID. SCDAEMON_INFO format (per upstream scdaemon.c):
#   SCDAEMON_INFO=<socket_path>:<pid>:<n>; export SCDAEMON_INFO
gnupg-pkcs11-scd --daemon --no-detach --homedir "$SCD_HOMEDIR" >/tmp/scd-info 2>&1 &
WRAPPER_PID=$!
wait "$WRAPPER_PID" || true
SCDAEMON_INFO="$(cat /tmp/scd-info)"
echo "$SCDAEMON_INFO"
INFO="${SCDAEMON_INFO#SCDAEMON_INFO=}"
INFO="${INFO%; export SCDAEMON_INFO}"
WORKER_PID="$(printf '%s' "$INFO" | awk -F: '{print $(NF-1)}')"
if ! [[ "$WORKER_PID" =~ ^[0-9]+$ ]] || [ "$WORKER_PID" -le 1 ]; then
  echo "Failed to extract worker PID from SCDAEMON_INFO: $SCDAEMON_INFO" >&2
  exit 1
fi
rm -f /tmp/scd-info
trap 'kill -TERM "$WORKER_PID" 2>/dev/null || true' TERM INT HUP
while kill -0 "$WORKER_PID" 2>/dev/null; do
  sleep 1 &
  wait $!
done
exit 0
```

### ci/goss.yaml

```yaml
---
file:
  /usr/bin/gnupg-pkcs11-scd:
    exists: true
  /usr/local/bin/entrypoint.sh:
    exists: true
    filetype: file
    filemode: 0755
  /var/lib/gnupg-pkcs11-scd:
    exists: true
    filetype: directory
  /var/run/gnupg-pkcs11-scd:
    exists: true
    filetype: directory
```

### ci/latest.sh

Returns the Debian bookworm `gnupg-pkcs11-scd` package version. Used by CI for drift display only; the Dockerfile pins a specific version.

## Image 2 — `infisical-pkcs11-provider` detail

### Dockerfile

Multi-stage: build downloads and verifies the upstream tarball; runtime stage is `FROM scratch` and ships only the resulting `.so` at root.

```dockerfile
FROM mirror.gcr.io/debian:trixie-slim AS build
ARG VERSION=0.0.3
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    base="https://github.com/Infisical/infisical-pkcs-11/releases/download/v${VERSION}"; \
    asset="libinfisical-pkcs11-linux-${TARGETARCH}.so.tar.gz"; \
    curl -fsSL -o checksums.txt "${base}/checksums-sha256.txt"; \
    curl -fsSL -o "${asset}"  "${base}/${asset}"; \
    grep " ${asset}\$" checksums.txt | sha256sum -c -; \
    mkdir -p /out; \
    tar -xzOf "${asset}" > /out/libinfisical-pkcs11.so; \
    chmod 0755 /out/libinfisical-pkcs11.so

FROM scratch

COPY --from=build /out/libinfisical-pkcs11.so /libinfisical-pkcs11.so
```

- `tar -xO` extracts the single-file tarball to stdout, which is redirected to the canonical filename (stripping the upstream arch suffix).
- SHA256 verified against the release's `checksums-sha256.txt`.
- No `USER`, `ENTRYPOINT`, `CMD`, or `VOLUME` — the image is a pure filesystem payload.

### ci/goss.yaml

```yaml
---
file:
  /libinfisical-pkcs11.so:
    exists: true
    filetype: file
```

### ci/latest.sh

```sh
#!/usr/bin/env bash
version="$(curl -sX GET "https://api.github.com/repos/Infisical/infisical-pkcs-11/releases" | jq --raw-output 'first(.[]) | .tag_name' 2>/dev/null)"
version="${version#v}"
printf "%s" "${version}"
```

## Cross-image contract

The two images communicate only through filesystem mounts. There is no shared network protocol.

| Sidecar path | Source | Provided by |
|---|---|---|
| `/var/run/gnupg-pkcs11-scd/gnupg-pkcs11-scd.*/agent.S` | Daemon's unix socket | `gnupg-pkcs11-scd` image; daemon creates the `XXXXXX` suffix via `mkdtemp(3)`. The shared volume is `/var/run/gnupg-pkcs11-scd`; consumers glob `gnupg-pkcs11-scd.*/agent.S` to find the actual socket. |
| `/providers/<name>/lib<name>*.so` | PKCS#11 library | Provider image's `/` bind-mounted to `/providers/<name>/`. |
| `${SCD_HOMEDIR}/gnupg-pkcs11-scd.conf` | Daemon config | Generated by entrypoint from env vars. Defaults to `/var/lib/gnupg-pkcs11-scd/gnupg-pkcs11-scd.conf`. |
| `/etc/infisical/pkcs11.conf` | Infisical library config | **Auto-generated by the entrypoint** at startup if absent. The Infisical library always reads this file (env vars alone are not enough); the entrypoint creates a minimal `{"log_level": "info"}` placeholder so the library can initialize. Real configuration is provided entirely via env vars (`INFISICAL_SERVER_URL`, `INFISICAL_UNIVERSAL_AUTH_CLIENT_ID`, `INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET`, or `INFISICAL_TOKEN`), which override values inside the config file. Users who need richer configuration (TLS settings, approval policies, custom caches) can mount their own file at the same path or set `INFISICAL_CONFIG` to a custom path. |

Infisical-specific credentials (`INFISICAL_UNIVERSAL_AUTH_CLIENT_ID`, `INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET`, `INFISICAL_SERVER_URL`) are passed as env vars on the scd container; they propagate through `gnupg-pkcs11-scd` to the dlopened library.

## Example wiring (docker compose)

```yaml
services:
  forgejo:
    image: codeberg/forgejo:8
    # ... user config ...
    # gpg-agent's scdaemon-program must point at the user-supplied shim
    # that bridges to /var/run/gnupg-pkcs11-scd/socket. That shim is not
    # part of these images.
    volumes:
      - scd-socket:/var/run/gnupg-pkcs11-scd:ro

  scd:
    image: ghcr.io/m00nwtchr/gnupg-pkcs11-scd:stable
    # PKCS11_PROVIDERS unset → auto-enumerate /providers/*
    environment:
      INFISICAL_UNIVERSAL_AUTH_CLIENT_ID: ${INFISICAL_CLIENT_ID}
      INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET: ${INFISICAL_CLIENT_SECRET}
    volumes:
      - scd-socket:/var/run/gnupg-pkcs11-scd
      - provider-vol:/providers/infisical

  infisical-provider:
    image: ghcr.io/m00nwtchr/infisical-pkcs11-provider:stable
    volumes:
      - provider-vol:/provider        # image root bind-mounted here
    command: ["sleep", "infinity"]

volumes:
  scd-socket:
  provider-vol:
```

After binding, the scd container sees `/providers/infisical/libinfisical-pkcs11.so`. The entrypoint enumerates `/providers/`, finds `infisical`, globs the `.so`, writes the conf at `/var/lib/gnupg-pkcs11-scd/gnupg-pkcs11-scd.conf`, exports `GNUPG_PKCS11_SOCKETDIR=/var/run/gnupg-pkcs11-scd`, and `exec`s the daemon. The daemon then creates `/var/run/gnupg-pkcs11-scd/gnupg-pkcs11-scd.XXXXXX/agent.S`.

The consumer (Forgejo-side shim) globs `/var/run/gnupg-pkcs11-scd/gnupg-pkcs11-scd.*/agent.S` to discover the actual socket path.

The k8s equivalent is an `initContainer` that copies the library out of the provider image into a shared `emptyDir`. The scd container then mounts it via `subPath` at the canonical provider path:

```yaml
initContainers:
  - name: copy-provider
    image: ghcr.io/m00nwtchr/infisical-pkcs11-provider:stable
    command: ["cp", "/libinfisical-pkcs11.so", "/provider/libinfisical-pkcs11.so"]
    volumeMounts:
      - name: provider-vol
        mountPath: /provider
containers:
  - name: scd
    image: ghcr.io/m00nwtchr/gnupg-pkcs11-scd:stable
    volumeMounts:
      - name: provider-vol
        mountPath: /providers/infisical/libinfisical-pkcs11.so
        subPath: libinfisical-pkcs11.so
volumes:
  - name: provider-vol
    emptyDir: {}
```

The `subPath` mount binds the single file from the shared volume directly to the canonical path the sidecar's glob expects, without requiring `mkdir` or a shell inside the `FROM scratch` provider image.

## Data flow (signing one commit)

1. K8s/Docker spins up the sidecar with `INFISICAL_*` env vars and the Infisical provider's `/` mounted at `/providers/infisical/`.
2. Entrypoint enumerates `/providers/`, finds `infisical`, globs `/providers/infisical/libinfisical*.so`, picks `libinfisical-pkcs11.so`, writes the daemon config, `exec`s the daemon.
3. Daemon opens `/var/run/gnupg-pkcs11-scd/socket`, dlopens the library. The library reads `INFISICAL_*` env vars and authenticates with Infisical.
4. Forgejo invokes `git commit -S`. `git` calls `gpg` → `gpg-agent` (running in the Forgejo container).
5. `gpg-agent`'s `scdaemon-program` is the user-supplied shim. The shim opens `/var/run/gnupg-pkcs11-scd/socket` (shared with the sidecar) and speaks assuan.
6. The daemon forwards the request to the library; the library calls Infisical's API and returns the signature.
7. `gpg-agent` hands the signature back to `git`. The commit/tag is signed.

## Error handling

| Failure | Behavior |
|---|---|
| `PKCS11_PROVIDERS` set to empty or unset with empty `/providers/` | Entrypoint exits 1 with a clear error message; container restarts until user fixes it. |
| Glob finds zero `.so` for an explicitly listed provider | Entrypoint exits 1 with the searched path. |
| Glob finds multiple `.so` for a provider | Entrypoint exits 1 listing matches; tells user to set `PKCS11_PROVIDER_<NAME>_LIBRARY`. |
| Override env var points at a non-existent file | Entrypoint exits 1. |
| Daemon crashes after start | Container exits; orchestrator restarts. Healthcheck (glob for `agent.S`) catches silent socket loss. |
| Provider image not yet mounted at startup | Empty `/providers/`; entrypoint fails fast. User must order pod startup so the volume is ready (k8s `initContainer` or compose `depends_on`). |
| Infisical config file missing | Library returns `CKR_GENERAL_ERROR` from `C_Initialize` (no log file created). The entrypoint auto-generates a minimal `{"log_level": "info"}` config to prevent this; the user only needs to set `INFISICAL_*` env vars. |
| Infisical auth fails | Library returns `CKR_GENERAL_ERROR`; daemon surfaces it via the assuan protocol. Diagnose via `log_level: debug` in a user-supplied `/etc/infisical/pkcs11.conf`. |

## Testing

### Image-level (goss)

- `gnupg-pkcs11-scd`: binary present at `/usr/bin/gnupg-pkcs11-scd`; entrypoint executable; directories `/var/lib/gnupg-pkcs11-scd` and `/var/run/gnupg-pkcs11-scd` exist.
- `infisical-pkcs11-provider`: file present at `/libinfisical-pkcs11.so`.

### Cross-image integration test (CI workflow)

A separate workflow (out of scope for these images) runs:

1. Start the sidecar with the provider image's contents mounted at `/providers/infisical/` and `PKCS11_PROVIDERS` unset.
2. Exec the entrypoint. Capture the generated `${SCD_HOMEDIR}/gnupg-pkcs11-scd.conf` (default `/var/lib/gnupg-pkcs11-scd/gnupg-pkcs11-scd.conf`).
3. Assert the file contains `providers infisical` and `provider-infisical-library /providers/infisical/libinfisical-pkcs11.so`.
4. Assert the daemon started and a socket exists at `/var/run/gnupg-pkcs11-scd/gnupg-pkcs11-scd.*/agent.S`.

This validates the cross-image contract without requiring a live Infisical signer.

### Verified end-to-end with real Infisical + real Forgejo

Tested with `code.forgejo.org/forgejo/forgejo:14.0.2-rootless` (gpg 2.4.9, gpg-agent 2.4.9) as the gpg-client container, sharing a `scd-keepid-vol` volume with the sidecar container, both in a pod with `--share ipc`. The gpg-client needed a small **scdaemon-shim** that bridges gpg-agent's assuan-protocol-on-stdio to the sidecar's Unix socket. The shim is a ~95KB statically-linked C binary built with `musl-gcc -static`. Source: `docs/examples/scdaemon-shim.c`.

Verified flow:
- `gpg --card-status` inside the Forgejo container returned the real Infisical signer's smartcard:
  ```
  Reader ...........: [none]
  Application ID ...: D27600012401115031313C19C15F1111
  Application type .: OpenPGP
  Version ..........: 11.50
  Serial number ....: 3C19C15F
  ```
- The shim is configured as `scdaemon-program` in `gpg-agent.conf`. The gpg-agent launches the shim with `--multi-server`; the shim ignores that arg and proxies assuan between the agent's stdio and the sidecar's socket.
- The shim uses `socket()`/`connect()` (NOT shell `exec N<>`) to open the unix socket, because `O_PATH` on unix sockets returns `ENXIO` from `connect()`.

Critical: in the gpg-client container, `gpg-agent.conf` must contain:
```
scdaemon-program /usr/local/bin/scdaemon-shim
allow-loopback-pinentry
```
The `allow-loopback-pinentry` is required so gpg-agent accepts passphrase input via the assuan pipe (gpg's passphrase prompt in non-interactive contexts).

### Recommended CI smoke (after this PR lands)

A follow-up CI step (in `.github/workflows/build-images.yaml` or a new workflow) should:

1. Build both images.
2. Start the sidecar with a stub `.so` mounted at `/providers/stub/` (e.g. an empty file is fine for this check — the daemon's PKCS#11 load will fail, but `mkdtemp` runs first so the socket should still appear briefly before the daemon exits; alternatively use `softhsm2` from a Debian container as the stub provider).
3. `docker exec` the sidecar and assert `${SCD_SOCKET_DIR}/gnupg-pkcs11-scd.*/agent.S` exists.

This guards against upstream changes to the daemon's `mkdtemp` template (`SOCKET_DIR_TEMPLATE`) which would silently break the healthcheck and the cross-image contract.

## README update

Add two rows to `README.md`:

```
[gnupg-pkcs11-scd](https://github.com/m00nwtchr/containers/pkgs/container/gnupg-pkcs11-scd) | stable | ghcr.io/m00nwtchr/gnupg-pkcs11-scd
[infisical-pkcs11-provider](https://github.com/m00nwtchr/containers/pkgs/container/infisical-pkcs11-provider) | stable | ghcr.io/m00nwtchr/infisical-pkcs11-provider
```

## Tradeoffs

| Decision | Alternative | Why this one |
|---|---|---|
| Debian 12 (bookworm) base for sidecar | Debian 13 (trixie) | Bookworm ships `gnupg-pkcs11-scd 0.10.0-2` (Debian's current stable line); trixie (testing) has `0.10.0-5`. We chose bookworm to match the existing `apps/debian` image in this repo and to avoid pinning against the testing migration. |
| Single-stage sidecar (no build stage) | Multi-stage build from source | Debian already packages it; no need to rebuild. Faster CI. |
| `FROM scratch` provider image | Minimal Debian runtime | The image carries only the library; no shell, no base layers, minimal attack surface. |
| Provider image contains only `/libinfisical-pkcs11.so` | Provider image contains a directory layout | User explicitly chose single-file-per-image to keep the mount contract trivial. |
| Provider mount: image `/` → sidecar `/providers/<name>/` | Direct file mount (image → single file) | File-on-file bind mounts are awkward; directory mount with one file inside is the standard OCI image-volume pattern. |
| Env-driven daemon config (`PKCS11_PROVIDERS`) | Mounted `gnupg-pkcs11-scd.conf` | Simpler k8s manifests; no ConfigMap required. The daemon has no `--config` flag, so the conf MUST be written into `${GNUPGHOME}/gnupg-pkcs11-scd.conf` at startup. |
| Auto-enumerate `/providers/*` by default | Require explicit `PKCS11_PROVIDERS` | Lower friction for the common case; explicit override still possible. |
| Daemon picks its own socket path via `mkdtemp` | Patch upstream to add `--socket` flag | The daemon has no `--socket` flag; we work with its conventions and let consumers glob for the `mkdtemp`-created path. |
| Skip silently on stray empty dir | Fail-fast | Robust to leftover empty mounts; explicit failures still catch real misconfigurations. |
| Verifying SHA256 from upstream checksums | Skip verification | Supply-chain integrity at near-zero cost. |

## Out of scope

- The shim binary on the Forgejo side (user-supplied; lives in the Forgejo pod or init container).
- Forgejo deployment manifests, Helm charts, or docker-compose production examples. The README example is illustrative only.
- Other PKCS#11 provider images (YubiHSM, softhsm, OpenSC, etc.). The contract supports them; each is a follow-up spec that mirrors the `infisical-pkcs11-provider` shape.
- `softhsm2` or any test provider image. The CI workflow can use a minimal stub.