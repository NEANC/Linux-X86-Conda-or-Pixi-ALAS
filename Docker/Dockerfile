ARG ALPINE_VERSION=3.21

# 构建阶段：下载并安装 glibc、Pixi、预构建 Pixi 虚拟环境
FROM alpine:${ALPINE_VERSION} AS builder

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG ALPINE_GLIBC_VERSION=2.35-r1

ENV PATH="/root/.pixi/bin:${PATH}" \
    CONDA_OVERRIDE_GLIBC="2.28"

COPY Docker/builder-proxy.sh /tmp/builder-proxy.sh
RUN chmod +x /tmp/builder-proxy.sh

# 步骤1：安装系统依赖（启用 community 仓库以支持 gcompat）
RUN set -eu; \
    . /tmp/builder-proxy.sh; \
    echo "https://dl-cdn.alpinelinux.org/alpine/v$(cut -d. -f1,2 /etc/alpine-release)/community" >> /etc/apk/repositories; \
    apk update; \
    apk add --no-cache \
        git \
        curl \
        ca-certificates \
        tar \
        xz \
        bash; \
    update-ca-certificates || true

# 步骤2：安装 gcompat（glibc 兼容层）
RUN set -eu; \
    . /tmp/builder-proxy.sh; \
    apk add --no-cache gcompat

# 步骤3：安装 sgerrand glibc（conda linux-64 Python 运行时依赖）
RUN set -eu; \
    . /tmp/builder-proxy.sh; \
    mkdir -p /etc/apk/keys /lib64 /tmp/glibc; \
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
        -o /etc/apk/keys/sgerrand.rsa.pub \
        https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub; \
    GLIBC_URL="https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${ALPINE_GLIBC_VERSION}"; \
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
        -o "/tmp/glibc/glibc-${ALPINE_GLIBC_VERSION}.apk" \
        "${GLIBC_URL}/glibc-${ALPINE_GLIBC_VERSION}.apk"; \
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
        -o "/tmp/glibc/glibc-bin-${ALPINE_GLIBC_VERSION}.apk" \
        "${GLIBC_URL}/glibc-bin-${ALPINE_GLIBC_VERSION}.apk"; \
    apk add --force-overwrite \
        "/tmp/glibc/glibc-${ALPINE_GLIBC_VERSION}.apk" \
        "/tmp/glibc/glibc-bin-${ALPINE_GLIBC_VERSION}.apk"; \
    ln -sf /usr/glibc-compat/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2; \
    rm -rf /tmp/glibc

# 步骤4：安装 Pixi
RUN set -eu; \
    . /tmp/builder-proxy.sh; \
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
        -o /tmp/pixi-install.sh \
        https://pixi.sh/install.sh; \
    sh /tmp/pixi-install.sh; \
    rm -f /tmp/pixi-install.sh; \
    pixi --version

# 步骤5：预构建 Pixi 虚拟环境
RUN mkdir -p /opt/alas-pixi-env

COPY Pixi/pixi.toml /opt/alas-pixi-env/pixi.toml

RUN set -eu; \
    . /tmp/builder-proxy.sh; \
    cd /opt/alas-pixi-env; \
    pixi install --manifest-path pixi.toml; \
    ./.pixi/envs/default/bin/python -V; \
    _pe=".pixi/envs/default"; \
    find "${_pe}" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true; \
    find "${_pe}" -type d -name tests -exec rm -rf {} + 2>/dev/null || true; \
    find "${_pe}" -type d -name test -exec rm -rf {} + 2>/dev/null || true; \
    rm -rf "${_pe}/share" "${_pe}/include" 2>/dev/null || true; \
    find "${_pe}" -name '*.a' -delete 2>/dev/null || true; \
    find "${_pe}" -name '*.la' -delete 2>/dev/null || true; \
    rm -rf /root/.cache/pip /root/.cache/pixi 2>/dev/null || true


# 运行阶段：仅保留运行时必需的文件
FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.title="ALAS Pixi Runtime (Alpine)"
LABEL org.opencontainers.image.description="Alpine Linux 下基于 Pixi 的 AzurLaneAutoScript 运行环境，ALAS 本体通过卷挂载传入"
LABEL org.opencontainers.image.source="https://github.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS"
LABEL maintainer="NEANC"

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

ENV LANG=C.UTF-8 \
    PATH="/root/.pixi/bin:${PATH}" \
    CONDA_OVERRIDE_GLIBC="2.28" \
    ALAS_DIR="/AzurLaneAutoScript" \
    ALAS_PIXI_PREBUILT="/opt/alas-pixi-env"

COPY --from=builder /usr/glibc-compat /usr/glibc-compat
COPY --from=builder /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=builder /root/.pixi /root/.pixi
COPY --from=builder /opt/alas-pixi-env /opt/alas-pixi-env

COPY Docker/builder-proxy.sh /tmp/builder-proxy.sh
RUN chmod +x /tmp/builder-proxy.sh

RUN set -eu; \
    . /tmp/builder-proxy.sh; \
    echo "https://dl-cdn.alpinelinux.org/alpine/v$(cut -d. -f1,2 /etc/alpine-release)/community" >> /etc/apk/repositories; \
    apk update; \
    apk add --no-cache \
        git \
        android-tools \
        ca-certificates \
        libstdc++ \
        libgcc \
        bash; \
    update-ca-certificates || true; \
    rm -rf /var/cache/apk/*

COPY Docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /AzurLaneAutoScript

EXPOSE 22267

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["start"]
