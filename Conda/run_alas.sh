#!/bin/bash

# 初始化 Conda
eval "$(~/miniforge3/bin/conda shell.bash hook)"
# 若无效，请注释/删除上述命令，后取消注释下列命令，并修改上述路径为实际安装路径
# 例：eval "$(/home/neanc/miniforge3/bin/conda shell.bash hook)" 或 eval "$(/root/miniforge3/bin/conda shell.bash hook)"
# eval "$(/root/miniforge3/bin/conda shell.bash hook)"

# 激活 alas 环境
conda activate alas

# 切换到 ALAS 目录
cd AzurLaneAutoScript
# 手动修改该行中的路径为 ALAS 目录，使用 `find / -name "AzurLaneAutoScript" -type d 2>/dev/null` 查询，例：/home/neanc/AzurLaneAutoScript 或 /root/AzurLaneAutoScript

# 运行 gui.py
python gui.py