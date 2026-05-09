# Linux-X86-Pixi-ALAS

> [!Tip]
> 本文默认读者对 Linux 下的命令行操作有基本了解；  
> 本文默认读者能正常访问 Github 与各官方库；  
> 如遇下载问题，请自行设置国内源或终端代理后再试。

在 X86_64 Linux 中使用 Pixi 安装与配置 [AzurLaneAutoScript](https://github.com/LmeSzinc/AzurLaneAutoScript) 的指南

---

> [!NOTE]
> [Pixi](https://pixi.prefix.dev/) 是 Miniforge 的下一代跨平台 Python 环境管理工具

## 1. 安装 Pixi

```bash
# 下载并运行 Pixi 安装脚本
curl -fsSL https://pixi.sh/install.sh | sh

# 检查 Pixi 版本号
pixi --version
```

---

> [!NOTE]
> [Git](https://git-scm.com/) 和 [Adb](https://developer.android.google.cn/tools/adb) 是 ALAS 运行所需工具

## 2. 安装 Git 及 Adb，及相关依赖库

1. 安装 Git 和 Adb，及相关依赖库

<details open>
  <summary> Debian/Ubuntu </summary>

```bash
# 更新软件包列表并安装 Git 和 Adb，及相关依赖库
apt update && apt install -y git adb libgomp1 libgl1 libglib2.0-0t64 libsm6 libxrender1 libxext6
```

</details>

<details>
  <summary> Arch Linux </summary>

```bash
pacman -Syy --noconfirm git android-tools libgomp mesa glib2 libsm libxrender libxext
```

</details>

<details>
  <summary> CentOS/RHEL/Fedora </summary>

```bash
dnf -q makecache && dnf -y install git android-tools libgomp mesa-libGL glib2 libSM libXrender libXext

yum install -y git android-tools libgomp mesa-libGL glib2 libSM libXrender libXext
```

</details>

2. 验证安装

```bash
# 检查 Adb 版本号
adb --version

# 检查 Git 版本号
git --version
```

---

## 3. 拉取 AzurLaneAutoScript

```bash
# 使用 Git 拉取 ALAS
git clone https://github.com/LmeSzinc/AzurLaneAutoScript/

# 切换到 ALAS 目录
cd AzurLaneAutoScript
```

---

> [!NOTE]
> [pixi.toml](./pixi.toml) 定义了 ALAS 虚拟环境配置

## 4. 下载 pixi.toml 文件

```bash
wget --show-progress -O pixi.toml https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Pixi/pixi.toml
```

> [!TIP]
> 若下载失败可使用国内源/代理加速，若均失败请阅读 [附录 配置 pixi.toml 文件](#附录-配置-pixitoml-文件)

---

## 5. 创建并配置虚拟环境

1. 在 ALAS 目录下运行下列命令：

```bash
pixi install
```

---

> [!IMPORTANT]
> 步骤 6. 需要在 ALAS 目录下操作  
> 该预设已经配置好地址与依赖路径，正常情况下无需再次修改

## 6. 配置 config/deploy.yaml

1. 在终端运行下列命令，重命名 `deploy.yaml` 文件

```bash
cp config/deploy.template-linux-cn.yaml config/deploy.yaml
```

---

## 7. 测试运行 ALAS

1. 进入脚本目录

```bash
cd AzurLaneAutoScript
```

2. 运行 GUI

```bash
pixi run python gui.py
```

3. 打开浏览器访问 `http://127.0.0.1:22267`，即可看到 ALAS WEB GUI

> [!CAUTION]
> 若报告未找到 `Git`、`Python`、`Adb` 路径，请阅读 [附录 填写依赖路径](#附录-填写依赖路径)

---

> [!IMPORTANT]
> 后续可以使用服务来运行 ALAS，避免终端关闭导致 ALAS 终止运行

> [!CAUTION]
> 使用服务运行前，必须进行下列操作：
>
> 1. 修改 `WorkingDirectory=/root/AzurLaneAutoScript` 与 `ExecStart=/root/.pixi/bin/pixi run start` 为实际路径  
> 2. 修改用户与用户组 `User=root` 与 `Group=root` 为实际用户与用户组，例如 `User=neanc` 与 `Group=neanc`  
> 3. 修改文件权限 `chmod 644 /etc/systemd/system/run_alas.service`

## 8. 配置开机自启

```bash
# 下载预设的 run_alas.service 文件
wget --show-progress -O /etc/systemd/system/run_alas.service https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Pixi/run_alas.service

# 按注释修改配置文件
nano /etc/systemd/system/run_alas.service

# 修改权限
chmod 644 /etc/systemd/system/run_alas.service

# 重载 systemd 配置
systemctl daemon-reload

# 设置 run_alas 服务开机启动
systemctl enable run_alas.service

# 启动服务
systemctl start run_alas.service

# 查看服务状态
systemctl status run_alas.service
```

---

## 附录 ALAS 运行后自动运行指定配置

修改 `./config/deploy.yaml` 中的 `Run` 参数，示例已在配置中列出

![Run 参数详细](../Image/deploy-RUN.png)

---

## 附录 删除虚拟环境

```bash
# 删除 ALAS 虚拟环境
pixi clean --environment alas

# 若重命名过 ALAS 虚拟环境，请自行参照下列命令自行删除虚拟环境
pixi clean --environment <环境名称>

# 删除所有虚拟环境
pixi clean
```

---

## 附录 配置 pixi.toml 文件

```bash
# 创建 pixi.toml 文件
nano pixi.toml
```

<details>
<summary>
📌 点击本行即可展开下列内容
</summary>

```yaml
[workspace]
channels = ["conda-forge"]
name = "alas"
platforms = ["linux-64"]
version = "0.1.0"

[tasks]
start = "python gui.py"

[dependencies]
python = "==3.7.6"
av = ">=8.0.3,<9"

[pypi-dependencies]
numpy = "==1.21.6"
scipy = "==1.4.1"
pillow = "*"
opencv-python = "*"
imageio = "==2.27.0"
adbutils = "==0.11.0"
uiautomator2 = "==2.16.17"
uiautomator2cache = "==0.3.0.1"
wrapt = "==1.13.1"
retrying = "*"
lz4 = "*"
av = "*"
psutil = "==5.9.3"
rich = "==11.2.0"
tqdm = "*"
jellyfish = "==0.11.2"
pyyaml = "*"
inflection = "*"
pydantic = "*"
aiofiles = "*"
prettytable = "==2.2.1"
anyio = "==1.3.1"
onepush = "==1.4.0"
pycryptodome = "==3.9.9"
pypresence = "==4.2.1"
cnocr = "==2.0.0"
mxnet = "==1.6.0"
pywebio = "==1.6.2"
starlette = "==0.14.2"
uvicorn = { version = "==0.17.6", extras = ["standard"] }
alas-webapp = "==0.3.7"
zerorpc = "==0.6.3"
pyzmq = "==22.3.0"
```

</details>

---

## 附录 填写依赖路径

> [!TIP]
> 若未找到对应路径，请重启终端后再试

1. 在终端逐行运行下列命令，分别查看并记录 `Git`、`Python`、`Adb` 的安装路径

```bash
# 查找 Git
which git

# 查找 Python
which python

# 查找 Adb
which adb
```

2. 打开 ALAS 目录下的 `config/deploy.yaml` 文件，找到并替换路径

```yaml
Git:
    # Filepath of git executable `git.exe`
    # [Easy installer] Use './toolkit/Git/mingw64/bin/git.exe'
    # [Other] Use you own git
    GitExecutable: /usr/bin/git
    # 把 which git 得到的地址替换这里，例如/usr/bin/git

  Python:
    # Filepath of python executable `python.exe`
    # [Easy installer] Use './toolkit/python.exe'
    # [Other] Use you own python, and its version should be 3.7.6 64bit
    PythonExecutable: python
    # 把 which python 得到的地址替换这里，例如/opt/homebrew/Caskroom/miniforge/base/envs/alas/bin/python3

  Adb:
    # Filepath of ADB executable `adb.exe`
    # [Easy installer] Use './toolkit/Lib/site-packages/adbutils/binaries/adb.exe'
    # [Other] Use you own latest ADB, but not the ADB in your emulator
    AdbExecutable: /usr/bin/adb
    # 把 which adb 得到的地址替换这里
```

---

## 附录 终端单次临时代理设置

在终端中运行即可

```bash
# <port> 为代理端口
export http_proxy="http://127.0.0.1:<port>"
export https_proxy="http://127.0.0.1:<port>"
```
