#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-and-push.sh — Build the tools image and push it to quay.io
#
# Compatible with both Docker and Podman.
# The engine is auto-detected (podman preferred when both are present).
# Override with --engine docker|podman.
#
# Target platform is always linux/amd64 (works from any host, incl. macOS ARM).
#
# Usage:
#   ./build-and-push.sh [OPTIONS]
#
# Options:
#   -r, --registry     Target registry              (default: quay.io)
#   -o, --org          Registry organisation/user   (required)
#   -i, --image        Image name                   (default: sterling-tools)
#   -t, --tag          Image tag                    (default: latest)
#       --kubectl      kubectl version              (default: v1.29.0)
#       --helm         Helm version                 (default: v3.14.4)
#       --oc           OC version                   (default: stable)
#       --push         Push after build             (default: false)
#       --engine       Container engine: docker|podman (default: auto-detect)
#   -h, --help         Show this help
# ---------------------------------------------------------------------------
set -euo pipefail

# ---------- defaults --------------------------------------------------------
REGISTRY="quay.io"
ORG=""
IMAGE="sterling-tools"
TAG="latest"
KUBECTL_VERSION="v1.29.0"
HELM_VERSION="v3.14.4"
OC_VERSION="stable"
PUSH=false
ENGINE=""
TARGET_PLATFORM="linux/amd64"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- argument parsing ------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--registry)    REGISTRY="$2";        shift 2 ;;
    -o|--org)         ORG="$2";             shift 2 ;;
    -i|--image)       IMAGE="$2";           shift 2 ;;
    -t|--tag)         TAG="$2";             shift 2 ;;
       --kubectl)     KUBECTL_VERSION="$2"; shift 2 ;;
       --helm)        HELM_VERSION="$2";    shift 2 ;;
       --oc)          OC_VERSION="$2";      shift 2 ;;
       --push)        PUSH=true;            shift   ;;
       --engine)      ENGINE="$2";          shift 2 ;;
    -h|--help)
      sed -n '/^# Usage:/,/^# ---/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------- engine detection ------------------------------------------------
if [[ -z "$ENGINE" ]]; then
  if command -v podman &>/dev/null; then
    ENGINE="podman"
  elif command -v docker &>/dev/null; then
    ENGINE="docker"
  else
    echo "ERROR: neither podman nor docker found in PATH"
    exit 1
  fi
fi

case "$ENGINE" in
  podman|docker) ;;
  *) echo "ERROR: --engine must be 'podman' or 'docker' (got: ${ENGINE})"; exit 1 ;;
esac

echo "[engine] Using ${ENGINE}"

# ---------- validation ------------------------------------------------------
if [[ -z "$ORG" ]]; then
  echo "ERROR: --org is required (e.g. --org myuser)"
  exit 1
fi

FULL_IMAGE="${REGISTRY}/${ORG}/${IMAGE}:${TAG}"

echo "============================================"
echo " Image   : ${FULL_IMAGE}"
echo " kubectl : ${KUBECTL_VERSION}"
echo " Helm    : ${HELM_VERSION}"
echo " OC      : ${OC_VERSION}"
echo " Platform: ${TARGET_PLATFORM}"
echo " Push    : ${PUSH}"
echo " Engine  : ${ENGINE}"
echo "============================================"

# ---------- build -----------------------------------------------------------
echo "[build] Building ${TARGET_PLATFORM} (cross-build safe for macOS ARM)"

if [[ "$ENGINE" == "podman" ]]; then
  # podman: --platform sets the target; --override-os/arch tells the resolver
  # to fetch linux/amd64 base layers even when the host is darwin/arm64.
  podman build \
    --platform "${TARGET_PLATFORM}"   \
    --build-arg "KUBECTL_VERSION=${KUBECTL_VERSION}" \
    --build-arg "HELM_VERSION=${HELM_VERSION}"       \
    --build-arg "OC_VERSION=${OC_VERSION}"           \
    -t "${FULL_IMAGE}"                               \
    -f "${SCRIPT_DIR}/Dockerfile"                    \
    "${SCRIPT_DIR}"

  if $PUSH; then
    echo "[push] Pushing ${FULL_IMAGE}"
    podman push "${FULL_IMAGE}"
  fi

else
  # docker: buildx handles cross-compilation transparently via QEMU/binfmt.
  # --load stores the image in the local daemon; swap for --push to push directly.
  docker buildx build \
    --platform "${TARGET_PLATFORM}"  \
    --build-arg "KUBECTL_VERSION=${KUBECTL_VERSION}" \
    --build-arg "HELM_VERSION=${HELM_VERSION}"       \
    --build-arg "OC_VERSION=${OC_VERSION}"           \
    -t "${FULL_IMAGE}"               \
    -f "${SCRIPT_DIR}/Dockerfile"    \
    $( $PUSH && echo "--push" || echo "--load" ) \
    "${SCRIPT_DIR}"
fi

echo ""
echo "Done."
if $PUSH; then
  echo "Image available at: ${FULL_IMAGE}"
else
  echo "Run with --push to publish the image."
fi
