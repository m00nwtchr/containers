#!/usr/bin/env bash

set -euo pipefail

LABEL_SELECTOR="kanidm_config=1"
NAMESPACE="kanidm"
BASE='{"groups": {}, "persons": {}, "systems": {"oauth2": {}}}'

KANIDM_TOKEN_FILE="${KANIDM_TOKEN_FILE:="$PWD/token"}"
KANIDM_TOKEN="${KANIDM_TOKEN:="$(cat "$KANIDM_TOKEN_FILE")"}"

KANIDM_INSTANCE="${KANIDM_INSTANCE:="https://idm.m00nlit.dev"}"

use_incluster_sa() {
  SA_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
  if [ -f "$SA_DIR/token" ] && [ -f "$SA_DIR/ca.crt" ]; then
    local tmp_config
    tmp_config="$(mktemp)"
    export KUBECONFIG="$tmp_config"

    # ensure cleanup on exit
    trap "rm -f \"${tmp_config}\"" EXIT

    local token ns cluster
    token="$(cat "$SA_DIR/token")"
    ns="$(cat "$SA_DIR/namespace")"
    cluster="https://[${KUBERNETES_SERVICE_HOST}]:${KUBERNETES_SERVICE_PORT}"

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

    echo "Using in-cluster serviceaccount (namespace: $ns)"
  else
    echo "No in-cluster serviceaccount found, using default kubeconfig"
  fi
}

get_basic_secret() {
  local rs
  rs="$1"
  curl -fsS \
    -H 'accept: application/json' \
    -H "Authorization: Bearer ${KANIDM_TOKEN}" \
    "${KANIDM_INSTANCE}/v1/oauth2/${rs}/_basic_secret" | jq -er
}

reconcile() {
  local all ns_clients
  # Snapshot all matching ConfigMaps (within $NAMESPACE) and pre-merge each CM's *.json into .data
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

  # Build: { "<ns>": ["clientA","clientB", ...], ... }
  ns_clients="$(
    printf '%s\n' "$all" |
      jq -c '
			sort_by(.namespace)
			| group_by(.namespace)
			| map({ (.[0].namespace): (map(.data.systems?.oauth2? // {} | keys) | add) })
			| add // {}
		'
  )"

  if [[ -e "/usr/local/bin/kanidm-provision" ]]; then
    local temp
    temp=$(mktemp)
    printf '%s\n' "$all" |
      jq -c --argjson base "$BASE" '
        $base * (map(.data) | reduce .[] as $item ({}; . * $item))
    ' >"$temp"
    cat "$temp" >&2

    KANIDM_TOKEN="$KANIDM_TOKEN" \
      kanidm-provision --no-auto-remove --url "$KANIDM_INSTANCE" --state "$temp"
    rm "$temp"
  fi

  # Iterate namespace/client pairs
  printf '%s\n' "$ns_clients" |
    jq -r '
		to_entries[]?
		| .key as $ns
		| (.value // [])[]
		| [$ns, .] | @tsv
	' |
    while IFS="$(printf '\t')" read -r ns client; do
      # Fetch secret string from Kanidm
      if ! secret="$(get_basic_secret "$client")"; then
        echo "warn: failed to fetch secret for client=$client (ns=$ns)" >&2
        continue
      fi
      [ -n "$secret" ] || {
        echo "warn: empty secret for client=$client (ns=$ns)" >&2
        continue
      }

      # Idempotent create/update via apply
      kubectl create secret generic -n "$ns" "${client}-oidc" \
        --from-literal=client-secret="$secret" \
        --dry-run=client -o yaml |
        kubectl apply -f -
    done
}

use_incluster_sa

# Initial reconcile at startup
reconcile

# Watch for changes and reconcile again
kubectl get configmaps -n "$NAMESPACE" -l "$LABEL_SELECTOR" --watch-only -o name |
  while read -r _; do
    reconcile
    sleep 1
  done
