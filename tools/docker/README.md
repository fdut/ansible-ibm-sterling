# Sterling Tools — Custom Docker Image

A UBI9-based image that bundles the CLI tools needed for IBM Sterling automation pipelines.

> **Engine support:** the build script works with both **Docker** and **Podman**.
> It auto-detects the engine (podman preferred when both are installed).
> Override with `--engine docker` or `--engine podman`.

## Included tools

| Tool      | Source                                      | Version (default) |
|-----------|---------------------------------------------|-------------------|
| `oc`      | mirror.openshift.com                        | stable            |
| `kubectl` | dl.k8s.io                                   | v1.29.0           |
| `helm`    | get.helm.sh                                 | v3.14.4           |
| `git`     | UBI9 dnf                                    | distro default    |
| `ansible` | pip3                                        | latest            |
| `jq`      | UBI9 dnf                                    | distro default    |
| `python3` | UBI9 dnf                                    | distro default    |

## Files

```
docker/
├── Dockerfile          # Image definition
├── .dockerignore       # Files excluded from build context
├── build-and-push.sh   # Helper script to build and push
└── README.md           # This file
```

## Quick start

### 1. Log in to quay.io

**Docker:**
```bash
docker login quay.io
```

**Podman:**
```bash
podman login quay.io
```

> **Tip:** prefer a [robot account token](https://docs.quay.io/glossary/robot-accounts.html) over your personal password.

### 2. Build and push

```bash
# Build only — engine auto-detected
./docker/build-and-push.sh --org <your-quay-org>

# Build + push
./docker/build-and-push.sh --org <your-quay-org> --push

# Force a specific engine
./docker/build-and-push.sh --org <your-quay-org> --engine podman --push
./docker/build-and-push.sh --org <your-quay-org> --engine docker --push

# Custom tool versions
./docker/build-and-push.sh \
  --org     myorg          \
  --tag     1.0.0          \
  --kubectl v1.30.0        \
  --helm    v3.15.0        \
  --oc      4.15           \
  --push
```

### 3. Multi-arch build (amd64 + arm64)

**With Docker** — requires `docker buildx` with a multi-platform builder:

```bash
docker buildx create --use --name multiarch
./docker/build-and-push.sh --org <your-quay-org> --multi-arch --push
```

**With Podman** — uses `podman manifest`; no extra setup needed:

```bash
./docker/build-and-push.sh --org <your-quay-org> --multi-arch --push
# (podman is auto-detected; or use --engine podman explicitly)
```

## Script options

| Flag              | Description                                        | Default          |
|-------------------|----------------------------------------------------|------------------|
| `-r, --registry`  | Target registry                                    | `quay.io`        |
| `-o, --org`       | Registry organisation / username                   | *(required)*     |
| `-i, --image`     | Image name                                         | `sterling-tools` |
| `-t, --tag`       | Image tag                                          | `latest`         |
| `--kubectl`       | kubectl version                                    | `v1.29.0`        |
| `--helm`          | Helm version                                       | `v3.14.4`        |
| `--oc`            | OC version                                         | `stable`         |
| `--push`          | Push after build                                   | `false`          |
| `--multi-arch`    | Build for linux/amd64 + linux/arm64                | `false`          |
| `--engine`        | Container engine: `docker` or `podman`             | auto-detect      |

## Use in a Tekton pipeline

```yaml
steps:
  - name: deploy
    image: quay.io/<your-quay-org>/sterling-tools:latest
    script: |
      oc login --token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) \
               --server=https://kubernetes.default.svc
      helm upgrade --install ...
```
