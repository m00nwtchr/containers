---
title: PKCS#11 Signing Sidecar Implementation Plan
date: 2026-07-08
spec: docs/superpowers/specs/2026-07-08-pkcs11-signing-sidecar-design.md
---

# PKCS#11 Signing Sidecar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build two container images — `gnupg-pkcs11-scd` (sidecar that runs the daemon with env-driven config generation) and `infisical-pkcs11-provider` (FROM-scratch image containing only the Infisical PKCS#11 library) — that together let a Forgejo pod sign git commits via PKCS#11.

**Architecture:** Two images linked by filesystem mounts only. The sidecar generates `${SCD_HOMEDIR}/gnupg-pkcs11-scd.conf` at startup from `PKCS11_PROVIDERS` and `/providers/<name>/lib<name>*.so` globs (daemon has no `--config` flag; config must live at `${GNUPGHOME}/gnupg-pkcs11-scd.conf`). The daemon names its own socket via `mkdtemp` at `${GNUPG_PKCS11_SOCKETDIR}/gnupg-pkcs11-scd.XXXXXX/agent.S`; consumers glob for `agent.S`. The provider image's `/` bind-mounts into the sidecar's `/providers/<name>/` to make the library discoverable. No network protocol between images.

**Tech Stack:** Debian 12 (bookworm) `gnupg-pkcs11-scd 0.10.0-2+b1` package; bash entrypoint; `FROM scratch` provider; `tar -xO` extraction; SHA256 verification; docker/buildx multi-arch via existing repo CI.

## Global Constraints

- Image 1 base: `mirror.gcr.io/debian:bookworm-slim`, pinned `gnupg-pkcs11-scd=0.10.0-2+b1` (no parens — dash rejects `(`), plus `ca-certificates` and `bash`. Single stage. (Original choice of trixie to get 0.11.0 was wrong — 0.11.0 is only in Debian sid; trixie has 0.10.0-5. Switched to bookworm to match `apps/debian` and stay on stable Debian.)
- Image 1 daemon (`gnupg-pkcs11-scd`) has NO `--config` and NO `--socket` flags. Config must live at `${GNUPGHOME}/gnupg-pkcs11-scd.conf`. Socket is created by the daemon itself at `${GNUPG_PKCS11_SOCKETDIR}/gnupg-pkcs11-scd.XXXXXX/agent.S` via `mkdtemp(3)`. Entrypoint sets `GNUPGHOME` (via `--homedir`), exports `GNUPG_PKCS11_SOCKETDIR`, and `exec`s `gnupg-pkcs11-scd --multi-server`. Consumers find the socket via glob.
- Image 2 base: `FROM scratch` for runtime, `mirror.gcr.io/debian:trixie-slim` for build substage. Downloads `Infisical/infisical-pkcs-11 v0.0.3` upstream tarballs, verifies SHA256 against `checksums-sha256.txt` from the same release.
- Image 2 ships exactly one file at root: `/libinfisical-pkcs11.so`. No `USER`, `ENTRYPOINT`, `CMD`, or `VOLUME`. No shell, no base layers beyond scratch.
- Image 1 socket dir: `/var/run/gnupg-pkcs11-scd` (mode 1777, declared `VOLUME`). Homedir: `/var/lib/gnupg-pkcs11-scd` (entrypoint writes `gnupg-pkcs11-scd.conf` here; daemon expects config at `${GNUPGHOME}/gnupg-pkcs11-scd.conf`). User: `1000:1000`.
- Image 1 entrypoint: bash script that generates `gnupg-pkcs11-scd.conf` from env vars (written to `${SCD_HOMEDIR}/gnupg-pkcs11-scd.conf`), then `exec`s `gnupg-pkcs11-scd --multi-server --homedir ${SCD_HOMEDIR}` with `GNUPG_PKCS11_SOCKETDIR` exported. Healthcheck: glob `/var/run/gnupg-pkcs11-scd/gnupg-pkcs11-scd.*/agent.S` for any socket file.
- `metadata.yaml` for both images: one `stable` channel, `linux/amd64` + `linux/arm64`, `tests.enabled: true, type: cli`, `semantic_versioning: true`.
- Commit messages follow conventional commits (enforced by pre-commit hook).
- Per-image directory layout: `apps/<name>/{Dockerfile,metadata.yaml}` and `apps/<name>/ci/{goss.yaml,latest.sh}`. Sidecar additionally has `apps/gnupg-pkcs11-scd/entrypoint.sh` (this is the ONE exception to the per-app layout — entrypoint scripts aren't part of any other app, but the sidecar needs one).
- All shell scripts must be executable (`chmod +x`); pre-commit hook enforces shebang + executable pairing.
- Final README is auto-rendered by `.github/workflows/render-readme.yaml`; no manual edit needed.

## File Structure

```
apps/
├── gnupg-pkcs11-scd/
│   ├── Dockerfile
│   ├── entrypoint.sh            (NEW — exception to per-app layout, justified by daemon config generation)
│   ├── metadata.yaml
│   └── ci/
│       ├── goss.yaml
│       └── latest.sh
└── infisical-pkcs11-provider/
    ├── Dockerfile
    ├── metadata.yaml
    └── ci/
        ├── goss.yaml
        └── latest.sh
```

No other files in the repo are touched. The README renders automatically from the new app directories.

---

## Task 1: `infisical-pkcs11-provider` skeleton (metadata + latest.sh)

The provider image is the simpler of the two and doesn't depend on the sidecar's contract at the filesystem level. We build it first so the sidecar's CI test (Task 6) has a real image to consume.

**Files:**
- Create: `apps/infisical-pkcs11-provider/metadata.yaml`
- Create: `apps/infisical-pkcs11-provider/ci/latest.sh`

**Interfaces:**
- Consumes: nothing
- Produces: metadata describing one `stable` channel; `latest.sh` printing the latest upstream `Infisical/infisical-pkcs-11` tag (e.g. `0.0.3`)

- [ ] **Step 1: Create `apps/infisical-pkcs11-provider/metadata.yaml`**

```yaml
---
app: infisical-pkcs11-provider
base: false
semantic_versioning: true
channels:
  - name: stable
    platforms: ["linux/amd64", "linux/arm64"]
    stable: true
    tests:
      enabled: true
      type: cli
```

- [ ] **Step 2: Create `apps/infisical-pkcs11-provider/ci/latest.sh`**

```sh
#!/usr/bin/env bash
version="$(curl -sX GET "https://api.github.com/repos/Infisical/infisical-pkcs-11/releases" | jq --raw-output 'first(.[]) | .tag_name' 2>/dev/null)"
version="${version#v}"
printf "%s" "${version}"
```

- [ ] **Step 3: Make `latest.sh` executable**

```bash
chmod +x apps/infisical-pkcs11-provider/ci/latest.sh
```

- [ ] **Step 4: Run `latest.sh` to confirm it produces a version string**

```bash
apps/infisical-pkcs11-provider/ci/latest.sh
```

Expected output: a version string like `0.0.3` (the script exits 0 even if upstream is unreachable, so the only failure mode is a curl/jq error).

- [ ] **Step 5: Validate metadata against `metadata.rules.cue`**

```bash
cue eval metadata.rules.cue
```

Expected: no errors. The `cue` binary may not be installed; if unavailable, skip and rely on CI to catch schema violations.

- [ ] **Step 6: Commit**

```bash
git add apps/infisical-pkcs11-provider/metadata.yaml apps/infisical-pkcs11-provider/ci/latest.sh
git commit -m "feat(infisical-pkcs11-provider): add metadata and latest.sh"
```

---

## Task 2: `infisical-pkcs11-provider` Dockerfile

Single-stage build downloads the upstream tarball, verifies SHA256, extracts the `.so` via `tar -xO`. Runtime stage is `FROM scratch`.

**Files:**
- Create: `apps/infisical-pkcs11-provider/Dockerfile`

**Interfaces:**
- Consumes: `apps/infisical-pkcs11-provider/metadata.yaml` (channel/arch)
- Produces: an image with one file at root, `/libinfisical-pkcs11.so`

- [ ] **Step 1: Write `apps/infisical-pkcs11-provider/Dockerfile`**

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

- [ ] **Step 2: Build the image locally to verify the recipe**

```bash
docker buildx build \
  --platform linux/amd64 \
  --build-arg VERSION=0.0.3 \
  --tag infisical-pkcs11-provider:test \
  --file apps/infisical-pkcs11-provider/Dockerfile \
  .
```

Expected: build completes without error. If the upstream URL or asset names have changed since the spec was written, the `curl` or `sha256sum -c` step will fail — update `VERSION` or asset naming accordingly.

- [ ] **Step 3: Inspect the built image to confirm only the `.so` is present**

```bash
docker run --rm infisical-pkcs11-provider:test ls -la /
docker run --rm infisical-pkcs11-provider:test cat /libinfisical-pkcs11.so | file -
```

Expected: listing shows exactly one entry, `/libinfisical-pkcs11.so`. The `file -` line should report an ELF shared object.

- [ ] **Step 4: Build for arm64 to confirm `TARGETARCH` substitution works**

```bash
docker buildx build \
  --platform linux/arm64 \
  --build-arg VERSION=0.0.3 \
  --tag infisical-pkcs11-provider:test-arm64 \
  --file apps/infisical-pkcs11-provider/Dockerfile \
  .
```

Expected: build completes without error.

- [ ] **Step 5: Commit**

```bash
git add apps/infisical-pkcs11-provider/Dockerfile
git commit -m "feat(infisical-pkcs11-provider): add Dockerfile with SHA256-verified download"
```

---

## Task 3: `infisical-pkcs11-provider` goss test

The image has no daemon, so the goss test is a simple file presence check.

**Files:**
- Create: `apps/infisical-pkcs11-provider/ci/goss.yaml`

**Interfaces:**
- Consumes: `apps/infisical-pkcs11-provider/Dockerfile` (produces `/libinfisical-pkcs11.so`)
- Produces: goss config validated by `dgoss run` in CI

- [ ] **Step 1: Write `apps/infisical-pkcs11-provider/ci/goss.yaml`**

```yaml
---
file:
  /libinfisical-pkcs11.so:
    exists: true
    filetype: file
```

- [ ] **Step 2: Run goss against the locally built image**

```bash
dgoss run --security-opt seccomp=unconfined infisical-pkcs11-provider:test
```

Expected: all checks pass. If `dgoss` is not installed locally, skip and rely on CI.

- [ ] **Step 3: Commit**

```bash
git add apps/infisical-pkcs11-provider/ci/goss.yaml
git commit -m "test(infisical-pkcs11-provider): add goss config"
```

---

## Task 4: `gnupg-pkcs11-scd` skeleton (metadata + latest.sh)

The sidecar image. Skeleton first; Dockerfile and entrypoint come in subsequent tasks.

**Files:**
- Create: `apps/gnupg-pkcs11-scd/metadata.yaml`
- Create: `apps/gnupg-pkcs11-scd/ci/latest.sh`

**Interfaces:**
- Consumes: nothing
- Produces: metadata + a `latest.sh` reporting the Debian bookworm `gnupg-pkcs11-scd` version

- [ ] **Step 1: Create `apps/gnupg-pkcs11-scd/metadata.yaml`**

```yaml
---
app: gnupg-pkcs11-scd
base: false
semantic_versioning: true
channels:
  - name: stable
    platforms: ["linux/amd64", "linux/arm64"]
    stable: true
    tests:
      enabled: true
      type: cli
```

- [ ] **Step 2: Create `apps/gnupg-pkcs11-scd/ci/latest.sh`**

The Debian bookworm package version is `0.10.0-2+b1`. Hardcode this — the Dockerfile pins it; this script is for CI drift display only and must match.

```sh
#!/usr/bin/env bash
printf "%s" "0.10.0-2+b1"
```

Rationale for hardcoding: the Dockerfile pins via `apt-get install (=${VERSION})`; CI drift detection only needs the version string, not a live query. Querying Debian APIs from CI would add a network dependency for no gain.

- [ ] **Step 3: Make `latest.sh` executable**

```bash
chmod +x apps/gnupg-pkcs11-scd/ci/latest.sh
```

- [ ] **Step 4: Verify `latest.sh` output**

```bash
apps/gnupg-pkcs11-scd/ci/latest.sh
```

Expected output: `0.10.0-2+b1`.

- [ ] **Step 5: Commit**

```bash
git add apps/gnupg-pkcs11-scd/metadata.yaml apps/gnupg-pkcs11-scd/ci/latest.sh
git commit -m "feat(gnupg-pkcs11-scd): add metadata and latest.sh"
```

---

## Task 5: `gnupg-pkcs11-scd` Dockerfile

Single-stage Debian bookworm image. Installs pinned `gnupg-pkcs11-scd`, copies the entrypoint (created in Task 7; for now we use a stub via a separate path), and sets up dirs.

**Files:**
- Create: `apps/gnupg-pkcs11-scd/Dockerfile`

**Interfaces:**
- Consumes: `apps/gnupg-pkcs11-scd/metadata.yaml`, `apps/gnupg-pkcs11-scd/entrypoint.sh` (Task 7)
- Produces: a runnable image that, once `entrypoint.sh` exists, generates config and execs the daemon

- [ ] **Step 1: Write `apps/gnupg-pkcs11-scd/Dockerfile`**

```dockerfile
FROM mirror.gcr.io/debian:bookworm-slim
ARG VERSION=0.10.0-2+b1

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

- [ ] **Step 2: Create a placeholder `entrypoint.sh` so the build doesn't fail**

The real entrypoint is written in Task 7. For this task's build to succeed, drop in a minimal stub that just execs the daemon with no config (the daemon will fail to find any providers and refuse to start, which is fine — we only need the build to succeed here).

```bash
cat > apps/gnupg-pkcs11-scd/entrypoint.sh <<'EOF'
#!/usr/bin/env bash
exec gnupg-pkcs11-scd --multi-server \
  --homedir /var/lib/gnupg-pkcs11-scd
EOF
chmod +x apps/gnupg-pkcs11-scd/entrypoint.sh
```

Note: the stub uses `--multi-server` (foreground) rather than `--daemon` (fork). The daemon rejects unknown flags (`--socket` and `--config` don't exist in upstream 0.10.0/0.11.0). The stub will exit because no providers are configured, which is fine for Task 5's build-only check.

- [ ] **Step 3: Build the image locally**

```bash
docker buildx build \
  --platform linux/amd64 \
  --build-arg VERSION=0.10.0-2+b1 \
  --tag gnupg-pkcs11-scd:test \
  --file apps/gnupg-pkcs11-scd/Dockerfile \
  apps/gnupg-pkcs11-scd
```

Expected: build completes. The `apt-get install gnupg-pkcs11-scd=0.10.0-2+b1` step must succeed against the Debian bookworm repo; if Debian repos change or the package is removed, this fails.

- [ ] **Step 4: Verify the binary is present**

```bash
docker run --rm gnupg-pkcs11-scd:test ls -la /usr/bin/gnupg-pkcs11-scd
```

Expected: file exists, mode 0755.

- [ ] **Step 5: Commit**

```bash
git add apps/gnupg-pkcs11-scd/Dockerfile apps/gnupg-pkcs11-scd/entrypoint.sh
git commit -m "feat(gnupg-pkcs11-scd): add Dockerfile with stub entrypoint"
```

---

## Task 6: `gnupg-pkcs11-scd` goss test

Static checks: binary, entrypoint, dirs.

**Files:**
- Create: `apps/gnupg-pkcs11-scd/ci/goss.yaml`

**Interfaces:**
- Consumes: `apps/gnupg-pkcs11-scd/Dockerfile`
- Produces: goss config

- [ ] **Step 1: Write `apps/gnupg-pkcs11-scd/ci/goss.yaml`**

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

- [ ] **Step 2: Run goss against the locally built image**

```bash
dgoss run --security-opt seccomp=unconfined gnupg-pkcs11-scd:test
```

Expected: all checks pass. (The stub entrypoint will exec the daemon, which will fail to find any provider config — the goss file checks pass regardless because they're static file/dir assertions.)

- [ ] **Step 3: Commit**

```bash
git add apps/gnupg-pkcs11-scd/ci/goss.yaml
git commit -m "test(gnupg-pkcs11-scd): add goss config"
```

---

## Task 7: `gnupg-pkcs11-scd` entrypoint (real implementation)

Replace the stub from Task 5 with the real entrypoint that generates `gnupg-pkcs11-scd.conf` from env vars.

**Files:**
- Modify: `apps/gnupg-pkcs11-scd/entrypoint.sh`

**Interfaces:**
- Consumes: env vars `PKCS11_PROVIDERS`, `PKCS11_PROVIDER_DIR`, `PKCS11_PROVIDER_<NAME>_LIBRARY`, `SCD_HOMEDIR`, `SCD_SOCKET_DIR`
- Produces: `${SCD_HOMEDIR}/gnupg-pkcs11-scd.conf` written before `exec`, daemon process running

- [ ] **Step 1: Write the real entrypoint**

Replace `apps/gnupg-pkcs11-scd/entrypoint.sh` with:

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
export GNUPG_PKCS11_SOCKETDIR="$SCD_SOCKET_DIR"
exec gnupg-pkcs11-scd --multi-server --homedir "$SCD_HOMEDIR"
```

- [ ] **Step 2: Confirm executable bit (the file should already be executable from Task 5)**

```bash
ls -l apps/gnupg-pkcs11-scd/entrypoint.sh
```

Expected: mode shows `0755` or `-rwxr-xr-x`.

- [ ] **Step 3: Lint the script with shellcheck**

```bash
shellcheck apps/gnupg-pkcs11-scd/entrypoint.sh
```

Expected: no errors. If `shellcheck` is unavailable, skip. If warnings are emitted, address them — common ones include quoting in `printf` and `shopt` usage.

- [ ] **Step 4: Rebuild the image**

```bash
docker buildx build \
  --platform linux/amd64 \
  --build-arg VERSION=0.10.0-2+b1 \
  --tag gnupg-pkcs11-scd:test \
  --file apps/gnupg-pkcs11-scd/Dockerfile \
  apps/gnupg-pkcs11-scd
```

Expected: build completes.

- [ ] **Step 5: Verify auto-enumerate behavior with no providers mounted**

```bash
docker run --rm --user 1000:1000 \
  --entrypoint /usr/local/bin/entrypoint.sh \
  gnupg-pkcs11-scd:test 2>&1 | head -5 || true
```

Expected: error message mentioning `PKCS11_PROVIDERS is empty and no provider directories found under /providers`. Exit code non-zero.

- [ ] **Step 6: Verify explicit-set-empty fails cleanly**

```bash
docker run --rm --user 1000:1000 \
  -e PKCS11_PROVIDERS= \
  gnupg-pkcs11-scd:test 2>&1 | head -5 || true
```

Expected: same error as Step 5. Exit code non-zero.

- [ ] **Step 7: Verify config generation with a stubbed provider**

Create a temporary directory structure and mount it:

```bash
mkdir -p /tmp/test-providers/infisical
touch /tmp/test-providers/infisical/libinfisical-pkcs11.so

docker run --rm --user 0:0 \
  -e PKCS11_PROVIDERS=infisical \
  -v /tmp/test-providers:/providers \
  gnupg-pkcs11-scd:test \
  cat /var/lib/gnupg-pkcs11-scd/gnupg-pkcs11-scd.conf
```

Expected output:

```
# Generated by entrypoint.sh — do not edit by hand.
providers infisical

# provider: infisical
provider-infisical-library /providers/infisical/libinfisical-pkcs11.so
```

Cleanup:
```bash
rm -rf /tmp/test-providers
```

- [ ] **Step 8: Verify auto-enumeration produces the same output**

```bash
mkdir -p /tmp/test-providers2/infisical
touch /tmp/test-providers2/infisical/libinfisical-pkcs11.so

docker run --rm --user 0:0 \
  -v /tmp/test-providers2:/providers \
  gnupg-pkcs11-scd:test \
  cat /var/lib/gnupg-pkcs11-scd/gnupg-pkcs11-scd.conf
```

Expected: same config content as Step 7.

Cleanup:
```bash
rm -rf /tmp/test-providers2
```

- [ ] **Step 9: Commit**

```bash
git add apps/gnupg-pkcs11-scd/entrypoint.sh
git commit -m "feat(gnupg-pkcs11-scd): implement entrypoint config generation"
```

---

## Task 8: End-to-end cross-image integration check

The two images together must satisfy the contract documented in the spec: a single `.so` from the provider image, mounted at `/providers/<name>/` in the sidecar, is found by the entrypoint's glob and produces the correct config line.

**Files:** none — verification only.

**Interfaces:**
- Consumes: built `infisical-pkcs11-provider:test-arm64` (or `:test`) and `gnupg-pkcs11-scd:test`
- Produces: a passed verification run

- [ ] **Step 1: Create a shared volume and run the provider image to populate it**

```bash
docker volume create provider-test-vol

docker run --rm \
  -v provider-test-vol:/provider \
  infisical-pkcs11-provider:test \
  cp /libinfisical-pkcs11.so /provider/libinfisical-pkcs11.so

docker run --rm \
  -v provider-test-vol:/data \
  alpine \
  ls -la /data
```

Expected: `/data/libinfisical-pkcs11.so` is listed.

- [ ] **Step 2: Run the sidecar with the provider contents mounted at `/providers/infisical/`**

```bash
docker run --rm \
  -v provider-test-vol:/providers/infisical \
  --user 0:0 \
  gnupg-pkcs11-scd:test \
  cat /var/lib/gnupg-pkcs11-scd/gnupg-pkcs11-scd.conf
```

Expected output:

```
# Generated by entrypoint.sh — do not edit by hand.
providers infisical

# provider: infisical
provider-infisical-library /providers/infisical/libinfisical-pkcs11.so
```

- [ ] **Step 3: Verify the sidecar starts and the socket appears**

```bash
docker run -d \
  --name scd-test \
  -v provider-test-vol:/providers/infisical \
  -v /tmp/scd-socket:/var/run/gnupg-pkcs11-scd \
  gnupg-pkcs11-scd:test

sleep 2
docker exec scd-test ls -la /var/run/gnupg-pkcs11-scd/
docker exec scd-test ls -la /var/run/gnupg-pkcs11-scd/gnupg-pkcs11-scd.*/ 2>/dev/null || echo "(no socket dir yet)"
```

Expected: `socket` file appears in the listing.

- [ ] **Step 4: Cleanup**

```bash
docker rm -f scd-test
docker volume rm provider-test-vol
rm -rf /tmp/scd-socket
```

- [ ] **Step 5: Commit any debug artifacts** (none expected; this task is verification only)

```bash
git status
```

Expected: clean working tree.

---

## Task 9: Final review and push

A final pass before merging: lint, schema check, README rendering, PR creation.

**Files:** none new; potential README change.

**Interfaces:**
- Consumes: all files from Tasks 1–8
- Produces: a PR ready for review

- [ ] **Step 1: Run pre-commit hooks against all new files**

```bash
pre-commit run --all-files
```

Expected: all hooks pass. The `check-executables-have-shebangs` and `check-shebang-scripts-are-executable` hooks will validate `entrypoint.sh` and `latest.sh`. The `conventional-pre-commit` hook only fires on `commit-msg` and won't run here.

- [ ] **Step 2: Validate metadata against CUE schema**

```bash
cue eval metadata.rules.cue
```

Expected: no errors.

- [ ] **Step 3: Push branch and open a PR**

```bash
git push origin HEAD
gh pr create \
  --title "feat: add gnupg-pkcs11-scd sidecar and infisical-pkcs11-provider images" \
  --body "Implements docs/superpowers/specs/2026-07-08-pkcs11-signing-sidecar-design.md. Adds two container images:
- gnupg-pkcs11-scd: sidecar that runs the daemon with env-driven config generation (PKCS11_PROVIDERS, /providers/* auto-enumeration).
- infisical-pkcs11-provider: FROM-scratch image containing the Infisical PKCS#11 module, designed to be mounted into the sidecar as an OCI image volume.
README is auto-rendered by CI on merge."
```

Expected: PR opened.

- [ ] **Step 4: Verify the PR's CI build runs both images**

Check the PR's checks page for the `Image Build` workflow running both `gnupg-pkcs11-scd` and `infisical-pkcs11-provider` per platform.

Expected: both images built on both `linux/amd64` and `linux/arm64`, goss tests pass.