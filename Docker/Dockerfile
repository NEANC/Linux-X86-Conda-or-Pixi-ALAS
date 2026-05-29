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

COPY Docker/local-channel /opt/local-channel
COPY Pixi/pixi.toml /opt/alas-pixi-env/pixi.toml

RUN set -eu; \
    . /tmp/builder-proxy.sh; \
    cd /opt/alas-pixi-env; \
    _pe="/opt/alas-pixi-env/.pixi/envs/default"; \
    if [ -d /opt/local-channel/linux-64 ] || [ -d /opt/local-channel/noarch ]; then \
        sed 's|channels = \["conda-forge"\]|channels = ["file:///opt/local-channel", "conda-forge"]|' pixi.toml > pixi.toml.tmp && mv pixi.toml.tmp pixi.toml; \
        sed 's|opencv = "\*"|opencv = "==4.5.5"|' pixi.toml > pixi.toml.tmp && mv pixi.toml.tmp pixi.toml; \
        mkdir -p /opt/local-channel/noarch; \
        if [ ! -f /opt/local-channel/noarch/repodata.json ]; then \
            printf '{"info":{"subdir":"noarch"},"packages":{}}\n' > /opt/local-channel/noarch/repodata.json; \
        fi; \
        echo "已强制锁定 OpenCV-mini channel 和版本"; \
        sed '/^mxnet = /d' pixi.toml > pixi.toml.tmp && mv pixi.toml.tmp pixi.toml; \
        sed '/^cnocr = /d' pixi.toml > pixi.toml.tmp && mv pixi.toml.tmp pixi.toml; \
        sed '/^\[pypi-dependencies\]/i\mxnet = "==1.6.0"' pixi.toml > pixi.toml.tmp && mv pixi.toml.tmp pixi.toml; \
        sed '/^mxnet = /a\cnocr = "==1.2.3.1"' pixi.toml > pixi.toml.tmp && mv pixi.toml.tmp pixi.toml; \
        sed '/^jellyfish = /i\gluoncv = ">=0.3,<0.7"' pixi.toml > pixi.toml.tmp && mv pixi.toml.tmp pixi.toml; \
        echo "已迁移 mxnet/cnocr → dependencies，注入 gluoncv"; \
    fi; \
    pixi install --manifest-path pixi.toml; \
    "$_pe/bin/python" -V; \
    echo "=== cv2 import 检查 ==="; \
    printf 'import cv2\nprint("cv2 path:", cv2.__file__)\ninfo = cv2.getBuildInformation()\nfor key in ["To be built", "PNG", "JPEG", "FFMPEG", "GStreamer", "GUI"]:\n    for line in info.splitlines():\n        if key in line:\n            print(line)\n' > /tmp/check_cv2.py; \
    "$_pe/bin/python" /tmp/check_cv2.py; \
    rm -f /tmp/check_cv2.py; \
    echo "=== MXNet 完整性检查 ==="; \
    pixi list --manifest-path pixi.toml | grep -Ei 'mxnet|cnocr|opencv' || true; \
    printf 'import mxnet as mx\nprint("mxnet:", mx.__version__)\na = mx.nd.array([1, 2, 3])\nassert (a + 1).asnumpy().tolist() == [2.0, 3.0, 4.0]\nfrom cnocr import CnOcr\nprint("mxnet/cnocr import OK")\n' > /tmp/check_mxnet.py; \
    "$_pe/bin/python" /tmp/check_mxnet.py; \
    if find "$_pe/lib/python3.7/site-packages/mxnet" -type f \( \
        -name 'libmklml_intel.so*' -o \
        -name 'libmkldnn.so*' \
    \) | grep -q .; then \
        echo "ERROR: PyPI/MKL MXNet was installed; expected MXNet-mini"; \
        find "$_pe/lib/python3.7/site-packages/mxnet" -type f \( \
            -name 'libmklml_intel.so*' -o \
            -name 'libmkldnn.so*' -o \
            -name 'libmxnet.so*' \
        \) -exec ls -lh {} \; ; \
        exit 1; \
    fi; \
    rm -f /tmp/check_mxnet.py; \
    echo "MXNet-mini 验证通过"; \
    echo "=== numpy.testing 检查 ==="; \
    if [ -d "$_pe/lib/python3.7/site-packages/numpy/testing" ]; then \
        echo "numpy/testing 目录存在"; \
    else \
        echo "ERROR: numpy/testing 目录缺失"; \
        exit 1; \
    fi; \
    echo "=== 清理前体积 ==="; \
    du -sh "$_pe" 2>/dev/null || true; \
    find "$_pe" -type d \( \
        -name __pycache__ -o \
        -name tests -o \
        -name test -o \
        -name benchmarks -o \
        -name benchmark \
    \) -prune -exec rm -rf {} + 2>/dev/null || true; \
    find "$_pe" -type f \( \
        -name "*.pyc" -o \
        -name "*.pyo" -o \
        -name "*.a" -o \
        -name "*.la" \
    \) -delete 2>/dev/null || true; \
    rm -rf \
        "$_pe/include" \
        "$_pe/share/doc" \
        "$_pe/share/man" \
        "$_pe/share/info" \
        "$_pe/share/gtk-doc" \
        "$_pe/share/gir-1.0" \
        "$_pe/share/locale" \
        "$_pe/share/opencv4" \
        "$_pe/share/qt" \
        "$_pe/share/terminfo" \
        "$_pe/translations" \
        "$_pe/qml" \
        "$_pe/mkspecs" \
        "$_pe/doc" \
        "$_pe/resources" \
        "$_pe/plugins" \
        "$_pe/lib/cmake" \
        "$_pe/lib/pkgconfig" \
        "$_pe/lib/libQt5"* \
        "$_pe/lib/libQt5WebEngine*" \
        "$_pe/lib/libx264"* \
        "$_pe/lib/libopenh264"* \
        "$_pe/share/ffmpeg" \
        "$_pe/bin/ffmpeg" \
        "$_pe/bin/ffprobe" \
        "$_pe/lib/python3.7/ensurepip" \
        "$_pe/bin/pip" \
        "$_pe/bin/pip3" \
        "$_pe/bin/pip3.7" \
        "$_pe/lib/python3.7/site-packages/pip" \
        "$_pe/lib/python3.7/site-packages/pip-"*".dist-info" \
        /root/.cache \
        /root/.rattler \
        /root/.cargo \
        /tmp/* \
        /var/tmp/* \
        2>/dev/null || true; \
    pixi clean cache --yes 2>/dev/null || true; \
    echo "=== 清理后体积 ==="; \
    du -sh "$_pe" 2>/dev/null || true; \
    echo "=== OpenCV 完整性检查 ==="; \
    pixi list --manifest-path pixi.toml | grep -Ei 'opencv|libopencv|py-opencv' || true; \
    if find "$_pe/lib" -maxdepth 1 -type f \( \
        -name 'libopencv_calib3d.so*' -o \
        -name 'libopencv_features2d.so*' -o \
        -name 'libopencv_flann.so*' -o \
        -name 'libopencv_highgui.so*' -o \
        -name 'libopencv_videoio.so*' -o \
        -name 'libopencv_objdetect.so*' -o \
        -name 'libopencv_photo.so*' -o \
        -name 'libopencv_stitching.so*' -o \
        -name 'libopencv_tracking.so*' -o \
        -name 'libopencv_xfeatures2d.so*' -o \
        -name 'libopencv_cvv.so*' \
    \) | grep -q .; then \
        echo "ERROR: full OpenCV libraries were installed; expected OpenCV-mini only"; \
        find "$_pe/lib" -maxdepth 1 -type f -name 'libopencv*.so*' -exec ls -lh {} \; ; \
        exit 1; \
    fi; \
    echo "OpenCV-mini 验证通过"


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
        bash \
        git \
        android-tools \
        ca-certificates \
        libstdc++ \
        libgcc; \
    update-ca-certificates || true; \
    rm -rf /tmp/builder-proxy.sh /var/cache/apk/* /tmp/* /var/tmp/*

COPY Docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /AzurLaneAutoScript

EXPOSE 22267

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["start"]
