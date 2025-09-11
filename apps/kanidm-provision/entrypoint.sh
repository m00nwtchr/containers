#!/usr/bin/env bash

set -euo pipefail

LABEL_SELECTOR="kanidm_config=1"
NAMESPACE="kanidm"
BASE='{"groups": {}, "persons": {}, "systems": {"oauth2": {}}}'

KANIDM_TOKEN_FILE="${KANIDM_TOKEN_FILE:="$PWD/token"}"
KANIDM_TOKEN="${KANIDM_TOKEN:="$(cat "$KANIDM_TOKEN_FILE")"}"

KANIDM_INSTANCE="${KANIDM_INSTANCE:="https://idm.m00nlit.dev"}"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

use_incluster_sa() {
  SA_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
  if [ -f "$SA_DIR/token" ] && [ -f "$SA_DIR/ca.crt" ]; then
    local tmp_config
    tmp_config="$(mktemp)"
    export KUBECONFIG="$tmp_config"
    trap 'rm -f "$KUBECONFIG"' EXIT

    local token ns cluster
    token="$(cat "$SA_DIR/token")"
    ns="$(cat "$SA_DIR/namespace")"

    host="${KUBERNETES_SERVICE_HOST:?KUBERNETES_SERVICE_HOST not set}"
    port="${KUBERNETES_SERVICE_PORT:-443}"

    # If it's an IPv6 literal (contains ':'), wrap in [ ]; if already bracketed, leave it.
    if [[ "$host" == *:* ]]; then
      if [[ "$host" != \[*\] ]]; then
        host="[$host]"
      fi
    fi

    cluster="https://${host}:${port}"

    kubectl config set-cluster in-cluster \
      --server="$cluster" \
      --certificate-authority="$SA_DIR/ca.crt" \
      --embed-certs=true >/dev/null

    kubectl config set-credentials in-cluster-user \
      --token="$token" >/dev/null

    kubectl config set-context in-cluster \
      --cluster=in-cluster \
      --user=in-cluster-user \
      --namespace="$ns" >/dev/null

    kubectl config use-context in-cluster >/dev/null
    log "Using in-cluster serviceaccount (namespace: $ns)"
  else
    log "No in-cluster serviceaccount found, using default kubeconfig"
  fi
}

wait_for_kanidm() {
  local url="${KANIDM_INSTANCE}/status"
  log "Waiting for Kanidm at $url"
  # Try until it responds with HTTP 200
  until curl -fsS "$url" >/dev/null 2>&1; do
    sleep 2
  done
  log "Kanidm is up"
}

get_basic_secret() {
  local rs
  rs="$1"
  curl -fsS \
    -H 'accept: application/json' \
    -H "Authorization: Bearer ${KANIDM_TOKEN}" \
    "${KANIDM_INSTANCE}/v1/oauth2/${rs}/_basic_secret" |
    jq -er '.'
}

reconcile() {
  # Run reconcile in a subshell; on any error, log and return success (non-fatal)
  (
    # everything inside still benefits from -euo pipefail
    local all ns_clients

    all="$(
      kubectl get configmaps -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o json |
        jq -c --arg ns "$NAMESPACE" '
				.items
				| map({
					name: .metadata.name,
					namespace: (.data.targetNamespace // $ns),
					data: (
						.data
						| to_entries
						| map(select(.key | endswith(".json")))
						| map(.value | fromjson)
						| reduce .[] as $item ({}; . * $item) # deep-merge within a single CM
					)
				})
			'
    )"

    ns_clients="$(
      printf '%s\n' "$all" |
        jq -c '
				sort_by(.namespace)
				| group_by(.namespace)
				| map({ (.[0].namespace): (map(.data.systems?.oauth2? // {} | keys) | add) })
				| add // {}
			'
    )"

    # Optional: provision from merged config over the base skeleton
    if [[ -x "/usr/local/bin/kanidm-provision" ]]; then
      local state
      state="$(mktemp)"
      printf '%s\n' "$all" |
        jq -c --argjson base "$BASE" '
				$base * (map(.data) | reduce .[] as $item ({}; . * $item))
			' >"$state"

      log "Provisioning with merged state (bytes: $(wc -c <"$state" | tr -d ' '))"

      if ! KANIDM_TOKEN="$KANIDM_TOKEN" \
        kanidm-provision --no-auto-remove --url "$KANIDM_INSTANCE" --state "$state"; then
        log "warn: kanidm-provision failed (state file: $state)"
      else
        rm -f "$state"
      fi
    fi

    # Iterate namespace/client pairs; create/update secrets idempotently
    printf '%s\n' "$ns_clients" |
      jq -r '
			to_entries[]?
			| .key as $ns
			| (.value // [])[]
			| [$ns, .] | @tsv
		' |
      while IFS="$(printf '\t')" read -r ns client; do
        if ! secret="$(get_basic_secret "$client")"; then
          log "warn: failed to fetch secret for client=$client (ns=$ns)"
          continue
        fi
        [ -n "$secret" ] || {
          log "warn: empty secret for client=$client (ns=$ns)"
          continue
        }

          secret_name="kanidm-${client}-oidc"

          # Try patching the secret first
          if ! kubectl patch secret -n "$ns" "$secret_name" \
              --type merge \
              -p "{\"stringData\": {\"client-secret\": \"${secret}\"}}" \
              >/dev/null 2>&1; then
            # If patch failed (likely not found), create the secret
            if ! kubectl create secret generic -n "$ns" "$secret_name" \
                  --from-literal=client-secret="$secret" \
                  >/dev/null 2>&1; then
              log "warn: failed to create or patch secret $ns/$secret_name"
              continue
            else
              log "created secret $ns/$secret_name"
            fi
          else
            log "patched secret $ns/$secret_name"
          fi
      done
  ) || {
    log "non-fatal: reconcile failed (will continue loop)"
    return 0
  }
}

use_incluster_sa

wait_for_kanidm

# Initial reconcile (non-fatal)
reconcile || log "non-fatal: initial reconcile failed"

# Watch loop: never exit the container on errors; restart the watch if it breaks
while true; do
  kubectl get configmaps -n "$NAMESPACE" -l "$LABEL_SELECTOR" --watch-only -o name |
    while read -r _; do
      reconcile || log "non-fatal: reconcile failed during watch event"
      sleep 1
    done
  log "watch stream ended or failed; restarting in 5s"
  sleep 5
done
