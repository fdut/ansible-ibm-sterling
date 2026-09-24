FROM --platform=linux/amd64 registry.access.redhat.com/ubi9/ubi:9.4

ARG KUBECTL_VERSION=v1.29.0
ARG HELM_VERSION=v3.14.4
ARG OC_VERSION=stable

LABEL maintainer="ansible-ibm-sterling" \
      description="Tooling image with oc, kubectl, helm, git, ansible, jq, python3 (linux/amd64)"

# Install system packages
# --allowerasing replaces curl-minimal (shipped by UBI9) with the full curl package
RUN dnf install -y --allowerasing \
        curl \
        git \
        jq \
        python3 \
        python3-pip \
        tar \
        unzip \
        wget \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Hard-wired to amd64 — no TARGETARCH branching needed.
RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
         -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    \
    # Install Helm \
    && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
         | tar -xz --strip-components=1 -C /usr/local/bin "linux-amd64/helm" \
    && chmod +x /usr/local/bin/helm \
    \
    # Install OpenShift CLI (oc) — rhel9 amd64 tarball \
    && curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OC_VERSION}/openshift-client-linux-amd64-rhel9.tar.gz" \
         | tar -xz -C /usr/local/bin oc \
    && chmod +x /usr/local/bin/oc

# Install Ansible + Python deps for kubernetes.core collection
RUN pip3 install --no-cache-dir \
        ansible \
        kubernetes \
        jsonpatch

# Install Ansible collections
RUN ansible-galaxy collection install kubernetes.core

# Verify binaries exist and are executable (file-check only — no execution,
# safe for cross-arch builds where running amd64 Go binaries under QEMU crashes).
RUN test -x /usr/local/bin/oc       \
    && test -x /usr/local/bin/kubectl \
    && test -x /usr/local/bin/helm    \
    && git --version                  \
    && ansible --version              \
    && jq --version                   \
    && python3 --version

WORKDIR /workspace

CMD ["/bin/bash"]
