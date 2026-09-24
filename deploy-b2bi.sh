#!/bin/bash
# =============================================================================
# deploy-b2bi.sh — Local launcher for IBM Sterling B2Bi install / uninstall
#
# Runs the Ansible playbook directly on your machine against the currently
# logged-in OpenShift cluster (no Tekton required).
#
# Usage:
#   ./deploy-b2bi.sh install    # install B2Bi (DB2 → setup DB2 → MQ → B2Bi)
#   ./deploy-b2bi.sh uninstall  # remove B2Bi, MQ and DB2 namespaces
#   ./deploy-b2bi.sh install -v # install with Ansible verbosity (-v / -vv / etc.)
#
# Prerequisites on your local machine:
#   - ansible-playbook   (pip install ansible)
#   - oc / kubectl       (already in your PATH)
#   - helm               (https://helm.sh/docs/intro/install/)
#   - python kubernetes  (pip install kubernetes)
#
# Required environment variables (set them before running or export in .env):
#   ENTITLED_REGISTRY_KEY   IBM Entitlement Key  (cp.icr.io)
#   SI_INSTANCEID           B2Bi instance id     e.g. dev01
#   SI_VERSION              B2Bi version         e.g. 6.2.2.0
#   SI_DBPASSWORD           DB2 password
#   SI_JMS_PASSWORD         MQ password
#
# Optional environment variables (have sensible defaults):
#   SI_ACTION               install | upgrade | prebuiltdb   (default: install)
#   SI_LICENSETYPE          prod | non-prod                  (default: non-prod)
#   SI_SYSTEM_PASSPHRASE    B2Bi system passphrase           (default: passw0rd)
#   SI_DBVENDOR             db2 | oracle | mssql             (default: db2)
#   SI_DBHOST               DB host (auto-discovered if empty)
#   SI_DBPORT               DB port                         (default: 50000)
#   SI_DBNAME               DB name                         (default: B2BIDB)
#   SI_DBUSER               DB user                         (default: db2inst1)
#   SI_ROUTEDOMAIN          OCP apps domain (auto-discovered)
#   SI_ENV_TIMEZONE         timezone                         (default: UTC)
#   STORAGE_CLASS_RWX       ReadWriteMany storage class (auto-discovered)
#   STORAGE_CLASS_RWO       ReadWriteOnce storage class (auto-discovered)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-}"
VERBOSITY="${2:-}"

# --------------------------------------------------------------------------
# Helper functions
# --------------------------------------------------------------------------
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

usage() {
  echo "Usage: $0 <install|uninstall> [-v|-vv|-vvv]"
  exit 1
}

# --------------------------------------------------------------------------
# Validate action
# --------------------------------------------------------------------------
[[ "$ACTION" == "install" || "$ACTION" == "uninstall" ]] || usage

# --------------------------------------------------------------------------
# Check required tools
# --------------------------------------------------------------------------
for tool in ansible-playbook oc helm python3; do
  command -v "$tool" &>/dev/null || error "Required tool not found: $tool"
done
python3 -c "import kubernetes" 2>/dev/null || \
  warn "Python 'kubernetes' module not found — run: pip install kubernetes"

# --------------------------------------------------------------------------
# Check OpenShift login
# --------------------------------------------------------------------------
if ! oc whoami &>/dev/null; then
  error "Not logged in to OpenShift. Run: oc login --server=<url> --token=<token>"
fi
OCP_SERVER=$(oc whoami --show-server)
OCP_TOKEN=$(oc whoami --show-token)
ok "Logged in as $(oc whoami) → $OCP_SERVER"

# --------------------------------------------------------------------------
# Check required environment variables
# --------------------------------------------------------------------------
: "${ENTITLED_REGISTRY_KEY:?'ENTITLED_REGISTRY_KEY is not set. Export your IBM Entitlement Key.'}"
: "${SI_INSTANCEID:?'SI_INSTANCEID is not set. E.g.: export SI_INSTANCEID=dev01'}"

# --------------------------------------------------------------------------
# Auto-discover cluster values if not set
# --------------------------------------------------------------------------
if [[ -z "${SI_ROUTEDOMAIN:-}" ]]; then
  SI_ROUTEDOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
  [[ -n "$SI_ROUTEDOMAIN" ]] && info "Auto-detected SI_ROUTEDOMAIN=$SI_ROUTEDOMAIN"
fi

if [[ -z "${STORAGE_CLASS_RWX:-}" ]]; then
  STORAGE_CLASS_RWX=$(oc get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null \
    | grep -E "cephfs|nfs|file" | head -1 | awk '{print $1}' || true)
  [[ -n "$STORAGE_CLASS_RWX" ]] && info "Auto-detected STORAGE_CLASS_RWX=$STORAGE_CLASS_RWX"
fi

if [[ -z "${STORAGE_CLASS_RWO:-}" ]]; then
  STORAGE_CLASS_RWO=$(oc get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null \
    | grep -E "ceph-rbd|block|gp" | head -1 | awk '{print $1}' || true)
  [[ -n "$STORAGE_CLASS_RWO" ]] && info "Auto-detected STORAGE_CLASS_RWO=$STORAGE_CLASS_RWO"
fi

# --------------------------------------------------------------------------
# Export all variables for ansible lookup('env', ...)
# --------------------------------------------------------------------------
export ENTITLED_REGISTRY_KEY
export SI_ACTION="${SI_ACTION:-install}"
export SI_INSTANCEID
export SI_VERSION="${SI_VERSION:-6.2.2.0}"
export SI_LICENSETYPE="${SI_LICENSETYPE:-non-prod}"
export SI_SYSTEM_PASSPHRASE="${SI_SYSTEM_PASSPHRASE:-passw0rd}"
export SI_DBVENDOR="${SI_DBVENDOR:-db2}"
export SI_DBHOST="${SI_DBHOST:-}"
export SI_DBPORT="${SI_DBPORT:-50000}"
export SI_DBNAME="${SI_DBNAME:-B2BIDB}"
export SI_DBUSER="${SI_DBUSER:-db2inst1}"
export SI_DBPASSWORD="${SI_DBPASSWORD:-}"
export SI_JMS_USERNAME="${SI_JMS_USERNAME:-}"
export SI_JMS_PASSWORD="${SI_JMS_PASSWORD:-}"
export SI_JMS_KEYSTORE_PASSWORD="${SI_JMS_KEYSTORE_PASSWORD:-changeit}"
export SI_JMS_TRUSTSTORE_PASSWORD="${SI_JMS_TRUSTSTORE_PASSWORD:-changeit}"
export SI_ROUTEDOMAIN="${SI_ROUTEDOMAIN:-}"
export SI_ENV_TIMEZONE="${SI_ENV_TIMEZONE:-UTC}"
export SI_ADMIN_MAILADDR="${SI_ADMIN_MAILADDR:-admin@company.com}"
export SI_ADMIN_SMTPHOST="${SI_ADMIN_SMTPHOST:-smtp.company.com}"
export STORAGE_CLASS_RWX="${STORAGE_CLASS_RWX:-}"
export STORAGE_CLASS_RWO="${STORAGE_CLASS_RWO:-}"
export KUBECONFIG="${HOME}/.kube/config"
export K8S_AUTH_KUBECONFIG="${KUBECONFIG}"
# Pass OCP credentials so roles that need oc login work
export OCP_SERVER
export OCP_TOKEN

# --------------------------------------------------------------------------
# Build ansible-playbook command
# --------------------------------------------------------------------------
cd "$SCRIPT_DIR"

if [[ "$ACTION" == "install" ]]; then
  PLAYBOOK="playbooks/deploy_sb2b.yml"
  info "Starting B2Bi INSTALL  (DB2 → setup DB2 → MQ → B2Bi)"
else
  PLAYBOOK="playbooks/cleanup/cleanup-sb2bi-all.yml"
  info "Starting B2Bi UNINSTALL"
fi

CMD="ansible-playbook"
[[ -n "$VERBOSITY" ]] && CMD="$CMD $VERBOSITY"
CMD="$CMD $PLAYBOOK"

echo ""
info "Command : $CMD"
info "Cluster : $OCP_SERVER"
info "Instance: $SI_INSTANCEID  version=$SI_VERSION  action=$SI_ACTION"
info "Storage : RWX=$STORAGE_CLASS_RWX  RWO=$STORAGE_CLASS_RWO"
echo ""

# --------------------------------------------------------------------------
# Execute
# --------------------------------------------------------------------------
$CMD
EXIT_CODE=$?

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
  ok "B2Bi $ACTION completed SUCCESSFULLY"
else
  error "B2Bi $ACTION FAILED (exit code: $EXIT_CODE)"
fi
