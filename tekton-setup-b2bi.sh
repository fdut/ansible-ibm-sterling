#!/bin/bash
# =============================================================================
# tekton-setup-b2bi.sh — Bootstrap Tekton pipeline for B2Bi on OpenShift
#
# This script:
#   1. Creates the sterling-deployer namespace
#   2. Installs OpenShift Pipelines operator (if not already present)
#   3. Creates the sterling-deploy-secrets Secret (OCP token + entitlement key)
#   4. Creates a service account with cluster-admin
#   5. Applies the Tekton Pipeline (pipeline-sterling-devops-deploy.yaml)
#   6. Triggers a PipelineRun for b2bi-install
#
# Usage:
#   export ENTITLED_REGISTRY_KEY="<your-ibm-entitlement-key>"
#   export SI_DBPASSWORD="<db2-password>"          # optional but recommended
#   export SI_JMS_PASSWORD="<mq-password>"         # optional but recommended
#   ./tekton-setup-b2bi.sh [install|uninstall]
#
# Requires: oc (already logged in), kubectl
# =============================================================================
set -euo pipefail

ACTION="${1:-install}"
NAMESPACE="sterling-deployer"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEKTON_DIR="$SCRIPT_DIR/tekton"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

[[ "$ACTION" == "install" || "$ACTION" == "uninstall" ]] || {
  echo "Usage: $0 [install|uninstall]"; exit 1
}

# --------------------------------------------------------------------------
# Check login
# --------------------------------------------------------------------------
oc whoami &>/dev/null || error "Not logged in to OpenShift. Run: oc login ..."
OCP_SERVER=$(oc whoami --show-server)
OCP_TOKEN=$(oc whoami --show-token)
ok "Logged in as $(oc whoami) → $OCP_SERVER"

# --------------------------------------------------------------------------
# UNINSTALL path — remove the PipelineRun and namespace
# --------------------------------------------------------------------------
if [[ "$ACTION" == "uninstall" ]]; then
  info "Deleting PipelineRun deploy-sterling-b2bi ..."
  oc delete pipelinerun deploy-sterling-b2bi -n "$NAMESPACE" --ignore-not-found
  info "Deleting Tekton resources in namespace $NAMESPACE ..."
  oc delete -f "$TEKTON_DIR/pipelines/pipeline-sterling-devops-deploy.yaml" -n "$NAMESPACE" --ignore-not-found
  ok "Tekton resources removed. Namespace $NAMESPACE kept (use 'oc delete ns $NAMESPACE' to fully remove)."
  exit 0
fi

# --------------------------------------------------------------------------
# INSTALL path
# --------------------------------------------------------------------------

# 1. Required variable
: "${ENTITLED_REGISTRY_KEY:?'Set: export ENTITLED_REGISTRY_KEY=<your-ibm-entitlement-key>'}"

# 2. Namespace
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
  info "Creating namespace $NAMESPACE ..."
  oc new-project "$NAMESPACE"
else
  ok "Namespace $NAMESPACE exists"
fi

# 3. OpenShift Pipelines Operator
# --------------------------------------------------------------------------
# wait_for_webhook: polls until tekton-pipelines-webhook svc + endpoints are
# ready in openshift-pipelines (up to ~5 min).  Called after fresh install AND
# on every run because the operator may still be rolling out from a prior run.
# --------------------------------------------------------------------------
wait_for_webhook() {
  info "Waiting for tekton-pipelines-webhook to be ready (up to 5 min) ..."
  for i in $(seq 1 60); do
    # Service must exist
    oc get svc tekton-pipelines-webhook -n openshift-pipelines &>/dev/null || { sleep 5; continue; }
    # At least one ready endpoint must exist
    READY=$(oc get endpoints tekton-pipelines-webhook -n openshift-pipelines \
              -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
    [[ -n "$READY" ]] && { ok "Webhook is ready"; return 0; }
    sleep 5
  done
  error "Timeout waiting for tekton-pipelines-webhook. Check: oc get pods -n openshift-pipelines"
}

info "Checking for OpenShift Pipelines operator ..."
if ! oc get sub -A 2>/dev/null | grep -qi "openshift-pipelines\|redhat-openshift-pipelines"; then
  info "Installing OpenShift Pipelines operator ..."
  oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  info "Waiting for Tekton CRDs to be ready (up to 3 min) ..."
  for i in $(seq 1 36); do
    oc get crd pipelines.tekton.dev &>/dev/null && break
    sleep 5
    [[ $i -eq 36 ]] && error "Timeout waiting for Tekton CRDs. Check operator status."
  done
  ok "OpenShift Pipelines operator installed"
else
  ok "OpenShift Pipelines operator already installed"
fi

# Always wait for the webhook — it may still be starting from a previous install
wait_for_webhook

# 4. Secret  (OCP credentials + entitlement key)
info "Creating/updating secret sterling-deploy-secrets ..."
oc delete secret sterling-deploy-secrets -n "$NAMESPACE" --ignore-not-found
oc create secret generic sterling-deploy-secrets \
  --from-literal=ENTITLED_REGISTRY_KEY="${ENTITLED_REGISTRY_KEY}" \
  --from-literal=OCP_SERVER="${OCP_SERVER}" \
  --from-literal=OCP_TOKEN="${OCP_TOKEN}" \
  --from-literal=SI_DBPASSWORD="${SI_DBPASSWORD:-passw0rd}" \
  --from-literal=SI_JMS_PASSWORD="${SI_JMS_PASSWORD:-passw0rd}" \
  -n "$NAMESPACE"
ok "Secret sterling-deploy-secrets created"

# 5. Service accounts
if ! oc get serviceaccount tekton-deployer-sa -n "$NAMESPACE" &>/dev/null; then
  info "Creating service account tekton-deployer-sa ..."
  oc create serviceaccount tekton-deployer-sa -n "$NAMESPACE"
  ok "Service account tekton-deployer-sa created"
else
  ok "Service account tekton-deployer-sa already exists"
fi
oc adm policy add-cluster-role-to-user cluster-admin \
  -z tekton-deployer-sa -n "$NAMESPACE"
ok "cluster-admin bound to tekton-deployer-sa"

# Also grant cluster-admin to the Tekton default 'pipeline' SA so that
# runs triggered without an explicit serviceAccountName still succeed.
oc adm policy add-cluster-role-to-user cluster-admin \
  -z pipeline -n "$NAMESPACE" 2>/dev/null || true
ok "cluster-admin bound to pipeline SA"

# 6. Tekton Pipeline
info "Applying Tekton Pipeline ..."
oc apply -f "$TEKTON_DIR/pipelines/pipeline-sterling-devops-deploy.yaml" -n "$NAMESPACE"
ok "Pipeline sterling-devops-deploy applied"

# 7. PipelineRun — delete old one if exists, then create fresh
info "Triggering PipelineRun deploy-sterling-b2bi ..."
oc delete pipelinerun deploy-sterling-b2bi -n "$NAMESPACE" --ignore-not-found
oc create -n "$NAMESPACE" -f - <<EOF
---
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: deploy-sterling-b2bi
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: sterling-b2bi
    app.kubernetes.io/component: deployment
    tekton.dev/pipeline: sterling-devops-deploy
  annotations:
    description: "Deploy B2Bi via pipeline-sterling-devops-deploy"
spec:
  pipelineRef:
    name: sterling-devops-deploy
  timeout: 3h0m0s
  serviceAccountName: tekton-deployer-sa
EOF
ok "PipelineRun deploy-sterling-b2bi submitted"

echo ""
echo "==========================================================="
ok "B2Bi Tekton pipeline launched!"
echo "==========================================================="
echo ""
echo "Monitor progress:"
echo "  oc get pipelinerun -n $NAMESPACE -w"
echo "  tkn pipelinerun logs deploy-sterling-b2bi -f -n $NAMESPACE"
echo ""
echo "Expected duration: 60–90 minutes"
echo "Stages: get-ibm-entitlement-key → set-ibm-entitlement-key → b2bi-install"
echo "==========================================================="
