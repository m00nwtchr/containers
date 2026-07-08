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
| `Dockerfile` | Single-stage `debian:trixie-slim`; installs pinned `gnupg-pkcs11-scd`; copies entrypoint; declares volumes. |
| `entrypoint.sh` | Generates the daemon config from env vars; `exec`s the daemon. |
| `metadata.yaml` | One `stable` channel, `linux/amd64` + `linux/arm64`, `tests.enabled: true, type: cli`. |
| `ci/latest.sh` | Reports the Debian trixie `gnupg-pkcs11-scd` version for CI drift display. |
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

Single stage, Debian 13 (trixie) to get `gnupg-pkcs11-scd 0.11.0-1` (current upstream):

```dockerfile
FROM mirror.gcr.io/debian:trixie-slim
ARG VERSION=0.11.0-1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      gnupg-pkcs11-scd (=${VERSION}) \
      ca-certificates \
      bash \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN mkdir -p /etc/gnupg-pkcs11-scd \
             /var/run/gnupg-pkcs11-scd \
             /var/lib/gnupg-pkcs11-scd \
 && chown 1000:1000 /etc/gnupg-pkcs11-scd /var/lib/gnupg-pkcs11-scd \
 && chmod 1777 /var/run/gnupg-pkcs11-scd

VOLUME ["/var/run/gnupg-pkcs11-scd"]

USER 1000:1000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

HEALTHCHECK CMD test -S /var/run/gnupg-pkcs11-scd/socket || exit 1
```

### Entrypoint contract (`entrypoint.sh`)

Steps:

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
4. **Write `/etc/gnupg-pkcs11-scd/gnupg-pkcs11-scd.conf`**:
   ```
   # Generated by entrypoint.sh — do not edit by hand.
   providers <comma-separated-names>

   # provider: <name>
   provider-<name>-library <resolved-path>
   ```
5. **`exec gnupg-pkcs11-scd --daemon --homedir=... --config=... --socket=...`** with the paths from `SCD_HOMEDIR` (default `/var/lib/gnupg-pkcs11-scd`) and `SCD_SOCKET` (default `/var/run/gnupg-pkcs11-scd/socket`).

### Environment variables

| Var | Default | Behavior |
|---|---|---|
| `PKCS11_PROVIDERS` | *(unset → auto-enumerate)* | Comma-separated names. Set explicitly to override auto-enum. Setting to an empty string disables auto-enum and produces a no-providers error. |
| `PKCS11_PROVIDER_DIR` | `/providers` | Root for glob and enumeration. |
| `PKCS11_PROVIDER_<NAME>_LIBRARY` | — | Full path to `.so`. Overrides glob for that provider. `<NAME>` is uppercased name with non-alphanumerics replaced by `_`. |
| `INFISICAL_*` | — | Pass-through env read by the Infisical library when loaded. Set on the scd container. |
| `SCD_SOCKET` | `/var/run/gnupg-pkcs11-scd/socket` | Daemon socket. |
| `SCD_HOMEDIR` | `/var/lib/gnupg-pkcs11-scd` | Daemon homedir. |

### Entrypoint script

`apps/gnupg-pkcs11-scd/entrypoint.sh`:

```sh
#!/usr/bin/env bash
set -eu

PROVIDER_DIR="${PKCS11_PROVIDER_DIR:-/providers}"
CONF="/etc/gnupg-pkcs11-scd/gnupg-pkcs11-scd.conf"

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
exec gnupg-pkcs11-scd --daemon \
  --homedir="${SCD_HOMEDIR:-/var/lib/gnupg-pkcs11-scd}" \
  --config="$CONF" \
  --socket="${SCD_SOCKET:-/var/run/gnupg-pkcs11-scd/socket}"
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
  /etc/gnupg-pkcs11-scd:
    exists: true
    filetype: directory
  /var/run/gnupg-pkcs11-scd:
    exists: true
    filetype: directory
```

### ci/latest.sh

Returns the Debian trixie `gnupg-pkcs11-scd` package version. Used by CI for drift display only; the Dockerfile pins a specific version.

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
version="$(curl -sX GET "https://api.github.com/repos/Infisical/infisical-pkcs-11/releases" | jq --rawOutput 'first(.[]) | .tag_name' 2>/dev/null)"
version="${version#v}"
printf "%s" "${version}"
```

## Cross-image contract

The two images communicate only through filesystem mounts. There is no shared network protocol.

| Sidecar path | Source | Provided by |
|---|---|---|
| `/var/run/gnupg-pkcs11-scd/socket` | Daemon's unix socket | `gnupg-pkcs11-scd` image; shared with Forgejo container. |
| `/providers/<name>/lib<name>*.so` | PKCS#11 library | Provider image's `/` bind-mounted to `/providers/<name>/`. |
| `/etc/infisical/pkcs11.conf` (optional) | Infisical library config | User-supplied; not shipped in either image. |

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

After binding, the scd container sees `/providers/infisical/libinfisical-pkcs11.so`. The entrypoint enumerates `/providers/`, finds `infisical`, globs the `.so`, and writes:

```
providers infisical
provider-infisical-library /providers/infisical/libinfisical-pkcs11.so
```

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
| Daemon crashes after start | Container exits; orchestrator restarts. Healthcheck catches silent socket loss. |
| Provider image not yet mounted at startup | Empty `/providers/`; entrypoint fails fast. User must order pod startup so the volume is ready (k8s `initContainer` or compose `depends_on`). |
| Infisical auth fails | Library returns `CKR_GENERAL_ERROR`; daemon surfaces it via the assuan protocol. Diagnose via `log_level: debug` in a user-supplied `/etc/infisical/pkcs11.conf`. |

## Testing

### Image-level (goss)

- `gnupg-pkcs11-scd`: binary present at `/usr/bin/gnupg-pkcs11-scd`; entrypoint executable; directories `/etc/gnupg-pkcs11-scd` and `/var/run/gnupg-pkcs11-scd` exist.
- `infisical-pkcs11-provider`: file present at `/libinfisical-pkcs11.so`.

### Cross-image integration test (CI workflow)

A separate workflow (out of scope for these images) runs:

1. Start the sidecar with the provider image's contents mounted at `/providers/infisical/` and `PKCS11_PROVIDERS` unset.
2. Exec the entrypoint. Capture the generated `/etc/gnupg-pkcs11-scd/gnupg-pkcs11-scd.conf`.
3. Assert the file contains `providers infisical` and `provider-infisical-library /providers/infisical/libinfisical-pkcs11.so`.
4. Assert the daemon started and `/var/run/gnupg-pkcs11-scd/socket` exists.

This validates the cross-image contract without requiring a live Infisical signer.

## README update

Add two rows to `README.md`:

```
[gnupg-pkcs11-scd](https://github.com/m00nwtchr/containers/pkgs/container/gnupg-pkcs11-scd) | stable | ghcr.io/m00nwtchr/gnupg-pkcs11-scd
[infisical-pkcs11-provider](https://github.com/m00nwtchr/containers/pkgs/container/infisical-pkcs11-provider) | stable | ghcr.io/m00nwtchr/infisical-pkcs11-provider
```

## Tradeoffs

| Decision | Alternative | Why this one |
|---|---|---|
| Debian 13 (trixie) base for sidecar | Debian 12 (bookworm) | trixie ships `gnupg-pkcs11-scd 0.11.0-1` (current upstream); bookworm has only `0.10.0-2`. |
| Single-stage sidecar (no build stage) | Multi-stage build from source | Debian already packages it; no need to rebuild. Faster CI. |
| `FROM scratch` provider image | Minimal Debian runtime | The image carries only the library; no shell, no base layers, minimal attack surface. |
| Provider image contains only `/libinfisical-pkcs11.so` | Provider image contains a directory layout | User explicitly chose single-file-per-image to keep the mount contract trivial. |
| Provider mount: image `/` → sidecar `/providers/<name>/` | Direct file mount (image → single file) | File-on-file bind mounts are awkward; directory mount with one file inside is the standard OCI image-volume pattern. |
| Env-driven daemon config (`PKCS11_PROVIDERS`) | Mounted `gnupg-pkcs11-scd.conf` | Simpler k8s manifests; no ConfigMap required. |
| Auto-enumerate `/providers/*` by default | Require explicit `PKCS11_PROVIDERS` | Lower friction for the common case; explicit override still possible. |
| Skip silently on stray empty dir | Fail-fast | Robust to leftover empty mounts; explicit failures still catch real misconfigurations. |
| Verifying SHA256 from upstream checksums | Skip verification | Supply-chain integrity at near-zero cost. |

## Out of scope

- The shim binary on the Forgejo side (user-supplied; lives in the Forgejo pod or init container).
- Forgejo deployment manifests, Helm charts, or docker-compose production examples. The README example is illustrative only.
- Other PKCS#11 provider images (YubiHSM, softhsm, OpenSC, etc.). The contract supports them; each is a follow-up spec that mirrors the `infisical-pkcs11-provider` shape.
- `softhsm2` or any test provider image. The CI workflow can use a minimal stub.