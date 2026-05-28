#!/bin/sh
set -eu

echo "===== 根目录体积 ====="
du -xh -d1 / 2>/dev/null | sort -h

echo ""
echo "===== /root 目录体积 ====="
du -xh -d2 /root 2>/dev/null | sort -h | tail -30

echo ""
echo "===== Pixi 环境体积 ====="
du -xh -d2 /opt/alas-pixi-env/.pixi/envs/default 2>/dev/null | sort -h | tail -80

echo ""
echo "===== site-packages 一级目录体积 ====="
du -xh -d1 /opt/alas-pixi-env/.pixi/envs/default/lib/python3.7/site-packages 2>/dev/null | sort -h | tail -80

echo ""
echo "===== lib 目录最大 .so 文件 Top 80 ====="
find /opt/alas-pixi-env/.pixi/envs/default/lib -type f -name "*.so*" 2>/dev/null \
  | xargs -r du -h \
  | sort -h \
  | tail -80

echo ""
echo "===== pixi list opencv ====="
cd /opt/alas-pixi-env
pixi list | grep -Ei "opencv|libopencv|py-opencv" || true

echo ""
echo "===== 可疑完整 OpenCV .so 检查 ====="
_pe=/opt/alas-pixi-env/.pixi/envs/default
find "$_pe/lib" -maxdepth 1 -type f \( \
  -name "libopencv_calib3d.so*" -o \
  -name "libopencv_features2d.so*" -o \
  -name "libopencv_flann.so*" -o \
  -name "libopencv_highgui.so*" -o \
  -name "libopencv_videoio.so*" -o \
  -name "libopencv_objdetect.so*" -o \
  -name "libopencv_photo.so*" -o \
  -name "libopencv_stitching.so*" -o \
  -name "libopencv_tracking.so*" -o \
  -name "libopencv_xfeatures2d.so*" -o \
  -name "libopencv_cvv.so*" \
\) -exec ls -lh {} \; || echo "(none found — good)"

echo ""
echo "===== cv2 构建信息 ====="
cd /opt/alas-pixi-env
./.pixi/envs/default/bin/python -c "
import cv2
print('cv2 path:', cv2.__file__)
info = cv2.getBuildInformation()
for key in ['To be built','GUI','FFMPEG','GStreamer','PNG','JPEG','TIFF','OpenCL','QT','GTK']:
    for line in info.splitlines():
        if key in line:
            print(line)
"

echo ""
echo "===== MXNet libraries ====="
find "$_pe/lib/python3.7/site-packages/mxnet" -maxdepth 2 -type f -name "*.so*" \
  -exec du -h {} \; 2>/dev/null | sort -h || true

echo ""
echo "===== MXNet import test ====="
./.pixi/envs/default/bin/python - <<'PY'
import mxnet as mx
print("mxnet:", mx.__version__)
a = mx.nd.array([1, 2, 3])
print((a + 1).asnumpy())
PY
