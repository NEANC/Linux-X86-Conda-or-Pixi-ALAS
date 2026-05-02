#!/bin/bash

# 初始化 Conda
source /root/miniforge3/bin/activate

# 激活 alas 环境
conda activate alas

# 切换到 ALAS 目录
cd AzurLaneAutoScript
# 手动修改该行中的路径为 ALAS 目录，例：/Users/Dreamry2C/AzurLaneAutoScript 或 /Users/NEANC/Downloads/AzurLaneAutoScript

# 运行 gui.py
python gui.py