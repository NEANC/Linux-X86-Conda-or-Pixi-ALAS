<#
.SYNOPSIS
    AzurLaneAutoScript Windows Conda 一键部署脚本
.DESCRIPTION
    静默执行，系统信息面板，步骤反馈
    支持 --debug 调试模式、--yes 静默卸载、--service 计划任务自启
#>

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$LogFile = "$env:TEMP\alas_install_$pid.log"
$null = New-Item -ItemType File -Path $LogFile -Force

$LogDateFormat = "HH:mm:ss"

function Write-InstallLog {
    param([string]$Level, [string]$Message)
    $timestamp = Get-Date -Format "${LogDateFormat}.fff"
    Add-Content -Path $LogFile -Value "${Level} | ${timestamp} | ${Message}"
}

function Write-Warn { param($m) Write-Host "  `u{26A0}`u{FE0F}  $m" -ForegroundColor Yellow }
function Write-ErrorMsg { param($m) Write-Host "  `u{274C}  $m" -ForegroundColor Red }

function Out-LogFile {
    begin {
        $teeArgs = @{ FilePath = $LogFile; Append = $true; ErrorAction = 'SilentlyContinue' }
    }
    process {
        if ($script:Debug) {
            $_ | Tee-Object @teeArgs
        } else {
            Add-Content -Path $LogFile -Value $_
        }
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments
    )
    $cmdDesc = "$FilePath $($Arguments -join ' ')"
    Write-InstallLog "CMD" $cmdDesc
    & $FilePath @Arguments 2>&1 | Out-LogFile
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($null -ne $code -and $code -ne 0) {
        throw "Command failed with exit code ${code}: ${cmdDesc}"
    }
}

$script:SpinnerJob = $null

function Start-Step {
    param([string]$Message)
    Stop-Spinner
    Write-InstallLog "START" $Message
    if ($script:Debug) {
        Write-Host "  `u{2699}`u{FE0F}  $Message" -ForegroundColor Yellow
        return
    }
    $spinChars = @('`u{280B}','`u{2819}','`u{2839}','`u{2838}','`u{283C}','`u{2834}','`u{2826}','`u{2827}','`u{2807}','`u{280F}')
    $script:SpinnerJob = Start-Job -ScriptBlock {
        $chars = $using:spinChars
        $msg = $using:Message
        $i = 0
        while ($true) {
            Write-Host "`r`e[33m$($chars[$i % 10])  $msg`e[0m`e[K" -NoNewline
            $i++
            Start-Sleep -Milliseconds 200
        }
    }
}

function Stop-Spinner {
    if ($script:SpinnerJob) {
        Stop-Job -Job $script:SpinnerJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:SpinnerJob -ErrorAction SilentlyContinue
        $script:SpinnerJob = $null
    }
}

function Complete-Step {
    param(
        [string]$Icon,
        [string]$Message,
        [string]$Color = "Green"
    )
    Stop-Spinner
    Write-Host "`r${Icon}  $Message`e[K" -ForegroundColor $Color
    $level = "INFO"
    switch ($Icon) {
        "`u{2714}`u{FE0F}" { $level = "OK" }
        "`u{26A0}`u{FE0F}" { $level = "WARNING" }
        "`u{274C}"         { $level = "ERROR" }
        "`u{1F4A1}"        { $level = "INFO" }
    }
    Write-InstallLog $level $Message
}

$InstallDir = "$env:USERPROFILE\AzurLaneAutoScript"
$ScriptOutDir = "$env:USERPROFILE\AzurLaneAutoScript"
$DeployTemplate = ".\config\deploy.template.yaml"
$UseCNMirror = $false
$GHProxy = ""
$WorkDir = ""
$AlasDir = ""
$CondaBin = ""
$UserName = [System.Environment]::UserName
$Uninstall = $false
$UninstallYes = $false
$KeepLog = $false
$Debug = $false
$SkipService = $false
$CreateService = $true

function Show-Usage {
    @"
用法: .\win_conda_alas_install.ps1 [选项]

选项:
  -d, --dir DIR           指定 ALAS 安装目录 (默认: ~\AzurLaneAutoScript)
  -s, --script-dir DIR    指定启动脚本输出目录 (默认: ~\AzurLaneAutoScript)
  -t, --template NAME|CN  控制使用的 deploy 模板与国内镜像源
  --uninstall [--yes]     反向安装：停止并删除 ALAS、虚拟环境
  -l, --log               保留安装日志，不自动删除
  --debug                 调试模式，日志将实时输出至终端
  -S, --setup-service     创建当前用户登录时启动的计划任务
  -h, --help              显示帮助信息
"@
}

for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        "-d"         { if ($i+1 -ge $args.Count) { Write-ErrorMsg "缺少参数值: -d"; exit 1 }; $InstallDir = $args[++$i]; break }
        "--dir"      { if ($i+1 -ge $args.Count) { Write-ErrorMsg "缺少参数值: --dir"; exit 1 }; $InstallDir = $args[++$i]; break }
        "-s"         { if ($i+1 -ge $args.Count) { Write-ErrorMsg "缺少参数值: -s"; exit 1 }; $ScriptOutDir = $args[++$i]; break }
        "--script-dir" { if ($i+1 -ge $args.Count) { Write-ErrorMsg "缺少参数值: --script-dir"; exit 1 }; $ScriptOutDir = $args[++$i]; break }
        "--scriptDir"  { if ($i+1 -ge $args.Count) { Write-ErrorMsg "缺少参数值: --scriptDir"; exit 1 }; $ScriptOutDir = $args[++$i]; break }
        "-t"         {
            if ($i+1 -ge $args.Count) { Write-ErrorMsg "缺少参数值: -t"; exit 1 }
            $next = $args[$i+1]
            if ($next -match "^(CN|cn)$") {
                $DeployTemplate = ".\config\deploy.template-cn.yaml"
                $UseCNMirror = $true
                $GHProxy = "https://ghfast.top/"
            } else {
                $DeployTemplate = $next
            }
            $i++
            break
        }
        "--template" {
            if ($i+1 -ge $args.Count) { Write-ErrorMsg "缺少参数值: --template"; exit 1 }
            $next = $args[$i+1]
            if ($next -match "^(CN|cn)$") {
                $DeployTemplate = ".\config\deploy.template-cn.yaml"
                $UseCNMirror = $true
                $GHProxy = "https://ghfast.top/"
            } else {
                $DeployTemplate = $next
            }
            $i++
            break
        }
        "--uninstall" {
            $Uninstall = $true
            if ($i+1 -lt $args.Count -and $args[$i+1] -match "^--(yes|Y)$") {
                $UninstallYes = $true
                $i++
            } elseif ($i+1 -lt $args.Count -and $args[$i+1] -match "^-(y|Y)$") {
                $UninstallYes = $true
                $i++
            }
            break
        }
        "--yes" { $UninstallYes = $true; break }
        "-Y"    { $UninstallYes = $true; break }
        "-y"    { $UninstallYes = $true; break }
        "-l"       { $KeepLog = $true; break }
        "--log"    { $KeepLog = $true; break }
        "--debug"  { $Debug = $true; break }
        "-debug"   { $Debug = $true; break }
        "--setup-service"      { $CreateService = $true; $SkipService = $false; break }
        "-S"             { $CreateService = $true; $SkipService = $false; break }
        "-h"     { Show-Usage; exit 0 }
        "--help" { Show-Usage; exit 0 }
        default  { Write-ErrorMsg "未知参数: $($args[$i])"; Show-Usage; exit 1 }
    }
}

function Test-Prerequisite {
    $os = Get-CimInstance Win32_OperatingSystem
    $verMajor = [int]$os.Version.Split('.')[0]
    if ($verMajor -lt 10) {
        Write-ErrorMsg "需要 Windows 10 或更高版本，当前版本: $($os.Caption)"
        Write-ErrorMsg "请使用 ALAS 官方安装器: https://alas.azurlane.cloud/"
        exit 1
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-ErrorMsg "未检测到 winget 包管理器"
        Write-ErrorMsg "请先安装 App Installer 或使用 ALAS 官方安装器: https://alas.azurlane.cloud/"
        exit 1
    }
}

function Get-SystemInfo {
    $script:NetIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" } | Select-Object -First 1).IPAddress
    if (-not $script:NetIP) { $script:NetIP = "未获取" }
    $os = Get-CimInstance Win32_OperatingSystem
    $script:OSVer = $os.Caption
    $cpu = Get-CimInstance Win32_Processor
    $script:CPUModel = $cpu.Name.Trim()
    $script:CPUCores = $cpu.NumberOfLogicalProcessors
    $disk = Get-PSDrive -Name C
    $script:DiskAvail = "{0:N0} GB" -f ($disk.Free / 1GB)
    $script:DiskUsed = "{0:N0} GB" -f (($disk.Used) / 1GB)
    $script:DiskInfo = "可用: $DiskAvail  已用: $DiskUsed"
    $script:RAMSizeMiB = "{0:N0}" -f ($os.TotalVisibleMemorySize / 1024)
}

function Show-Header {
    try {
        Clear-Host
    } catch {
        [System.Console]::Write([char]27 + "[2J" + [char]27 + "[H")
    }
    Write-Host @"

    ___    __    ___   _____
   /   |  / /   /   | / ___/
  / /| | / /   / /| | \__ \
 / ___ |/ /___/ ___ |___/ /
/_/  |_/_____/_/  |_/____/

"@
    Write-Host "  `u{1F5A5}`u{FE0F}  Windows 中基于 Conda 的 ALAS 部署脚本"
    Write-Host "  ─────────────────────────────────────────────────"
    Write-Host "  `u{1F4A1}  当前局域网 IP  : $NetIP" -ForegroundColor Blue
    Write-Host "  `u{2699}`u{FE0F}  Windows 版本   : $OSVer" -ForegroundColor Green
    Write-Host "  `u{1F5A5}`u{FE0F}   CPU 型号       : $CPUModel" -ForegroundColor Green
    Write-Host "  `u{1F9E0}  CPU 核心数     : $CPUCores" -ForegroundColor Green
    Write-Host "  `u{1F4BE}  磁盘大小       : $DiskInfo" -ForegroundColor Blue

    $ramColor = "Green"
    if ([int]$RAMSizeMiB -lt 8000) { $ramColor = "Yellow" }
    elseif ([int]$RAMSizeMiB -lt 16000) { $ramColor = "Blue" }
    Write-Host "  `u{1F9EE}  内存大小       : $RAMSizeMiB MiB" -ForegroundColor $ramColor

    $userColor = "Green"
    if ($UserName -eq "SYSTEM") { $userColor = "Yellow" }
    Write-Host "  `u{1F194}  当前用户       : $UserName" -ForegroundColor $userColor
    Write-Host ""
}

function Find-CondaExe {
    $candidates = @()

    if ($env:CONDA) {
        $candidates += Join-Path $env:CONDA "Scripts\conda.exe"
        $candidates += Join-Path $env:CONDA "condabin\conda.bat"
    }

    $candidates += @(
        "$env:USERPROFILE\miniforge3\Scripts\conda.exe",
        "$env:USERPROFILE\Miniforge3\Scripts\conda.exe",
        "$env:USERPROFILE\miniconda3\Scripts\conda.exe",
        "$env:USERPROFILE\Miniconda3\Scripts\conda.exe",
        "$env:USERPROFILE\anaconda3\Scripts\conda.exe",
        "$env:USERPROFILE\Anaconda3\Scripts\conda.exe",
        "C:\Miniconda\Scripts\conda.exe",
        "C:\Miniconda\condabin\conda.bat",
        "C:\ProgramData\miniforge3\Scripts\conda.exe",
        "C:\ProgramData\Miniforge3\Scripts\conda.exe",
        "C:\ProgramData\miniconda3\Scripts\conda.exe",
        "C:\ProgramData\Miniconda3\Scripts\conda.exe"
    )

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            return $c
        }
    }

    $cmdConda = Get-Command conda -ErrorAction SilentlyContinue
    if ($cmdConda) {
        return $cmdConda.Source
    }

    return $null
}

function Install-Miniforge {
    Start-Step "正在检查 Miniforge..."

    $foundConda = Find-CondaExe
    if ($foundConda) {
        $script:CondaBin = $foundConda
        try {
            $ver = (& $foundConda --version 2>$null | ForEach-Object { $_ }) -join ""
            Write-InstallLog "OK" "Conda 已就绪: $ver"
            Complete-Step -Icon "`u{2714}`u{FE0F}" "Conda 已就绪: $ver"
            return
        } catch {
            Write-InstallLog "WARNING" "检测到 conda 但无法获取版本，继续安装 Miniforge"
        }
    }

    Write-InstallLog "ERROR" "未检测到 Conda"
    Start-Step "正在安装 Miniforge..."
    Write-InstallLog "EXEC" "`u{25B6} winget install CondaForge.Miniforge3"

    try {
        $proc = Start-Process -FilePath "winget" -ArgumentList "install","CondaForge.Miniforge3","--silent","--accept-package-agreements","--accept-source-agreements" -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "winget 安装 Miniforge 失败 (exit $($proc.ExitCode))"
        }
        Write-InstallLog "OK" "`u{2713} Miniforge 安装完成"
    } catch {
        Complete-Step -Icon "`u{274C}" "Miniforge 安装错误，详情请阅读日志：$LogFile" "Red"
        throw
    }

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

    $foundConda = Find-CondaExe
    if ($foundConda) {
        $script:CondaBin = $foundConda
        try {
            $ver = (& $foundConda --version 2>$null | ForEach-Object { $_ }) -join ""
            Complete-Step -Icon "`u{2714}`u{FE0F}" "Miniforge 已安装: $ver"
        } catch {
            Complete-Step -Icon "`u{2714}`u{FE0F}" "Miniforge 已安装"
        }
    } else {
        Write-InstallLog "ERROR" "Miniforge 安装后未找到 conda 可执行文件"
        Complete-Step -Icon "`u{274C}" "Miniforge 安装失败，请查看日志：$LogFile" "Red"
        throw "Miniforge 安装后未找到 conda 可执行文件"
    }
}

function Install-GitADB {
    Start-Step "正在检查依赖..."

    $needsInstall = @()
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { $needsInstall += "Git.Git" }
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { $needsInstall += "Google.PlatformTools" }

    if ($needsInstall.Count -eq 0) {
        Write-InstallLog "OK" "Git: $(git --version)"
        Write-InstallLog "OK" "ADB: $(adb --version 2>$null | Select-Object -First 1)"
        Complete-Step -Icon "`u{2714}`u{FE0F}" "依赖检查完成"
        return
    }

    Start-Step "正在安装缺失的依赖: $($needsInstall -join ', ')..."
    foreach ($pkg in $needsInstall) {
        Write-InstallLog "EXEC" "`u{25B6} winget install $pkg"
        try {
            $proc = Start-Process -FilePath "winget" -ArgumentList "install",$pkg,"--silent","--accept-package-agreements","--accept-source-agreements" -Wait -PassThru
            if ($proc.ExitCode -eq 0) {
                Write-InstallLog "OK" "`u{2713} $pkg 安装完成"
            } else {
                Write-InstallLog "WARNING" "winget 安装 $pkg 返回码: $($proc.ExitCode)"
            }
        } catch {
            Write-InstallLog "WARNING" "winget 安装 $pkg 失败，请手动安装"
        }
    }

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

    $gitVer = git --version 2>$null
    $adbVer = adb --version 2>$null | Select-Object -First 1
    Write-InstallLog "OK" "Git: $gitVer"
    Write-InstallLog "OK" "ADB: $adbVer"
    Complete-Step -Icon "`u{2714}`u{FE0F}" "依赖安装完成"
}

function Sync-ALASRepo {
    Start-Step "正在克隆 ALAS 仓库..."

    $script:WorkDir = $InstallDir

    if (Test-Path $WorkDir) {
        $originUrl = ""
        if (Test-Path "$WorkDir\.git") {
            try {
                $originUrl = git -C "$WorkDir" remote get-url origin 2>$null
            } catch { $null = $_ }
        }

        if ($originUrl -match 'github\.com[:/]+LmeSzinc/AzurLaneAutoScript(\.git)?$') {
            Write-InstallLog "OK" "git 远程 URL 验证通过: $originUrl"
            Write-InstallLog "WARNING" "ALAS 仓库已存在，跳过克隆: $WorkDir"
            Complete-Step -Icon "`u{26A0}`u{FE0F}" "ALAS 仓库已存在，跳过克隆" "Yellow"
            Set-Location $WorkDir
            $script:AlasDir = $WorkDir
            return
        }

        if (-not $originUrl) {
            Write-InstallLog "WARNING" "目录 $WorkDir 中无 .git 信息，可能是非完整 ALAS 安装，将覆盖安装"
            Write-InstallLog "EXEC" "`u{25B6} 删除旧目录: Remove-Item $WorkDir"
            Remove-Item $WorkDir -Recurse -Force -ErrorAction Stop
        } else {
            Write-InstallLog "ERROR" "安装目录已存在，但不是 AzurLaneAutoScript 仓库: $WorkDir (remote: $originUrl)"
            Complete-Step -Icon "`u{274C}" "安装目录已存在且是其他 git 仓库 ($originUrl)，请使用 -d 参数指定目录" "Red"
            exit 1
        }
    }

    $repoUrl = "https://github.com/LmeSzinc/AzurLaneAutoScript.git"
    Write-InstallLog "EXEC" "`u{25B6} git clone ${GHProxy}${repoUrl} $WorkDir"

    try {
        Invoke-Native -FilePath git -Arguments clone,"${GHProxy}${repoUrl}","$WorkDir"
        Write-InstallLog "OK" "`u{2713} 仓库克隆完成"
    } catch {
        Complete-Step -Icon "`u{274C}" "仓库克隆错误，详情请阅读日志：$LogFile" "Red"
        throw
    }

    Set-Location $WorkDir
    $script:AlasDir = $WorkDir
    Write-InstallLog "OK" "ALAS 目录: $AlasDir"
    Complete-Step -Icon "`u{2714}`u{FE0F}" "ALAS 仓库已克隆"
}

function Initialize-CondaEnv {
    Start-Step "正在配置 Conda 虚拟环境..."

    Set-Location $AlasDir

    $envFile = Join-Path $AlasDir "environment.windows.generated.yml"
    Write-InstallLog "EXEC" "`u{25B6} 生成 $envFile"

    $envYml = @'
name: alas
channels:
  - conda-forge
platforms:
  - win-64
dependencies:
  - python=3.7.9
  - av>=8.0.3,<9
  - numpy=1.16.6
  - scipy=1.4.1
  - psutil=5.9.3
  - pyyaml
  - tqdm
  - lz4
  - pyzmq=22.3.0
  - pip
  - pip:
      - pillow
      - opencv-python==4.5.5.62
      - imageio==2.27.0
      - adbutils==0.11.0
      - uiautomator2==2.16.17
      - uiautomator2cache==0.3.0.1
      - wrapt==1.13.1
      - retrying==1.3.3
      - rich==11.2.0
      - jellyfish==0.11.2
      - inflection==0.5.1
      - pydantic==1.9.2
      - aiofiles==0.8.0
      - prettytable==2.2.1
      - anyio==1.3.1
      - onepush==1.4.0
      - pycryptodome==3.9.9
      - pypresence==4.2.1
      - cnocr==1.2.2
      - mxnet==1.6.0
      - pywebio==1.6.2
      - starlette==0.14.2
      - uvicorn==0.17.6
      - websockets==10.4
      - alas-webapp==0.3.7
      - zerorpc==0.6.3
'@

    Set-Content -Path $envFile -Value $envYml
    Write-InstallLog "OK" "`u{2713} $envFile 已生成"

    if ($UseCNMirror) {
        $cernetConda = "https://mirrors.cernet.edu.cn/anaconda"
        $cernetPypi = "https://mirrors.cernet.edu.cn/pypi/web/simple"

        Write-InstallLog "EXEC" "`u{25B6} 配置国内镜像源 (cernet)"
        & $CondaBin config --prepend channels "$cernetConda/cloud/conda-forge/" 2>&1 | Out-LogFile
        & $CondaBin config --prepend channels "$cernetConda/pkgs/main/" 2>&1 | Out-LogFile

        $env:PIP_INDEX_URL = $cernetPypi
        $env:PIP_TRUSTED_HOST = "mirrors.cernet.edu.cn"
        $env:PIP_TIMEOUT = "60"
        Write-InstallLog "OK" "`u{2713} 国内镜像源已配置"
    }

    try {
        $envInfo = & $CondaBin env list --json 2>$null | ConvertFrom-Json
        $alasExists = $envInfo.envs | Where-Object { Split-Path $_ -Leaf -eq "alas" }
    } catch {
        $envList = & $CondaBin env list 2>$null
        $alasExists = $envList -match "^alas "
    }
    if ($alasExists) {
        Write-InstallLog "WARNING" "检测到已有 alas 环境，正在移除..."
        Write-InstallLog "EXEC" "`u{25B6} conda clean -a -y"
        try {
            & $CondaBin clean -a -y 2>&1 | Out-LogFile
        } catch {
            Write-InstallLog "WARNING" "conda clean 失败，继续移除环境"
        }
        Write-InstallLog "EXEC" "`u{25B6} conda env remove -n alas -y"
        try {
            & $CondaBin env remove -n alas -y 2>&1 | Out-LogFile
        } catch {
            $envsPath = & $CondaBin info --base 2>$null
            if ($envsPath -and (Test-Path "$envsPath\envs\alas")) {
                Remove-Item "$envsPath\envs\alas" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Write-InstallLog "OK" "`u{2713} 旧环境已移除"
    }

    $attempt = 1
    $cnFallbackDone = $false
    $installLog = "$env:TEMP\conda_install_$pid.log"

    while ($true) {
        Write-InstallLog "EXEC" "`u{25B6} conda env create -f $envFile (第 ${attempt} 次，这可能需要较长时间)"
        & $CondaBin env create -f $envFile 2>&1 | Tee-Object -FilePath $installLog | Out-LogFile
        $envCreateCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0

        if ($envCreateCode -eq 0) {
            Write-InstallLog "OK" "`u{2713} conda env create 完成"
            Remove-Item $installLog -Force -ErrorAction SilentlyContinue
            break
        }

        $errContent = Get-Content $installLog -Raw -ErrorAction SilentlyContinue

        if ($UseCNMirror -and (-not $cnFallbackDone) -and ($errContent -match "403|403 Forbidden")) {
            Write-InstallLog "WARNING" "国内镜像源不可用（403 Forbidden），自动降级到官方源"
            Remove-Item $installLog -Force -ErrorAction SilentlyContinue
            $cnFallbackDone = $true
            & $CondaBin config --remove channels "https://mirrors.cernet.edu.cn/anaconda/cloud/conda-forge/" 2>&1 | Out-LogFile
            & $CondaBin config --remove channels "https://mirrors.cernet.edu.cn/anaconda/pkgs/main/" 2>&1 | Out-LogFile
            $env:PIP_INDEX_URL = $null
            & $CondaBin env remove -n alas -y 2>&1 | Out-LogFile
            $attempt++
            continue
        }

        Complete-Step -Icon "`u{274C}" "虚拟环境构建错误，详情请阅读日志：$LogFile" "Red"
        Remove-Item $installLog -Force -ErrorAction SilentlyContinue
        throw "conda env create failed with exit code $envCreateCode"
    }

    $env:PIP_INDEX_URL = $null

    Write-InstallLog "EXEC" "`u{25B6} 验证环境: python -c 'import alas_webapp'"
    & $CondaBin run -n alas python -c "import alas_webapp,cv2,uiautomator2,adbutils,yaml" 2>&1 | Out-LogFile
    if ($LASTEXITCODE -ne 0) {
        $global:LASTEXITCODE = 0
        Write-InstallLog "WARNING" "`u{26A0} 依赖完整性检查未通过，尝试修复..."
        & $CondaBin env update -n alas --file $envFile 2>&1 | Out-LogFile
        $global:LASTEXITCODE = 0
        Write-InstallLog "OK" "`u{2713} 依赖修复完成"

        Write-InstallLog "EXEC" "`u{25B6} 二次验证: python -c 'import alas_webapp'"
        & $CondaBin run -n alas python -c "import alas_webapp,cv2,uiautomator2,adbutils,yaml" 2>&1 | Out-LogFile
        if ($LASTEXITCODE -ne 0) {
            Write-InstallLog "ERROR" "二次验证仍失败，请查看日志"
            Complete-Step -Icon "`u{274C}" "依赖修复后验证仍失败，请查看日志：$LogFile" "Red"
            throw "conda run import check failed after env update"
        }
        $global:LASTEXITCODE = 0
        Write-InstallLog "OK" "`u{2713} 二次验证通过"
    } else {
        Write-InstallLog "OK" "`u{2713} 依赖完整性检查通过"
    }

    Complete-Step -Icon "`u{2714}`u{FE0F}" "虚拟环境已构建"
}

function Set-Deploy {
    Start-Step "配置 config\deploy.yaml"

    Set-Location $AlasDir

    if (Test-Path config\deploy.yaml) {
        Write-InstallLog "EXEC" "`u{25B6} 备份已有 deploy.yaml"
        Copy-Item config\deploy.yaml config\deploy.yaml.bak -Force
    }

    $template = $DeployTemplate

    if (Test-Path $template) {
        Write-InstallLog "EXEC" "`u{25B6} cp $template config\deploy.yaml"
        Copy-Item $template config\deploy.yaml -Force
    } else {
        Write-InstallLog "WARNING" "模板文件 $template 不存在，生成默认 deploy.yaml"
    }

    $pyPath = ""
    try {
        $condaBase = & $CondaBin info --base 2>$null
        if ($condaBase) {
            $pyCandidate = Join-Path $condaBase "envs\alas\python.exe"
            if (Test-Path -LiteralPath $pyCandidate) {
                $pyPath = $pyCandidate -replace '\\', '/'
            }
        }
    } catch {
        $pyCandidate = Join-Path $AlasDir ".pixi\envs\default\python.exe"
        if (Test-Path -LiteralPath $pyCandidate) {
            $pyPath = $pyCandidate -replace '\\', '/'
        }
    }
    if (-not $pyPath) {
        $pyPath = "python"
    }

    $gitPath = "git"
    try {
        $gitCmd = Get-Command git -ErrorAction Stop
        $gitPath = $gitCmd.Source -replace '\\', '/'
    } catch { $null = $_ }

    $adbPath = "adb"
    try {
        $adbCmd = Get-Command adb -ErrorAction Stop
        $adbPath = $adbCmd.Source -replace '\\', '/'
    } catch { $null = $_ }

    if (-not (Test-Path config\deploy.yaml)) {
        $defaultDeploy = @"
Deploy:
  PythonExecutable: $pyPath
  GitExecutable: $gitPath
  AdbExecutable: $adbPath
"@
        Set-Content -Path config\deploy.yaml -Value $defaultDeploy
        Write-InstallLog "OK" "`u{2713} 已生成 config\deploy.yaml"
    } else {
        $content = Get-Content config\deploy.yaml -Raw -Encoding UTF8
        $content = $content -replace 'PythonExecutable:\s*\.\/toolkit\/python\.exe', "PythonExecutable: $pyPath"
        $content = $content -replace 'PythonExecutable:\s*\.\\toolkit\\python\.exe', "PythonExecutable: $pyPath"
        $content = $content -replace 'GitExecutable:\s*\.\/toolkit\/Git\/mingw64\/bin\/git\.exe', "GitExecutable: $gitPath"
        $content = $content -replace 'GitExecutable:\s*\.\\toolkit\\Git\\mingw64\\bin\\git\.exe', "GitExecutable: $gitPath"
        $content = $content -replace 'AdbExecutable:\s*\.\/toolkit\/Lib\/site-packages\/adbutils\/binaries\/adb\.exe', "AdbExecutable: $adbPath"
        $content = $content -replace 'AdbExecutable:\s*\.\\toolkit\\Lib\\site-packages\\adbutils\\binaries\\adb\.exe', "AdbExecutable: $adbPath"
        Set-Content -Path config\deploy.yaml -Value $content -NoNewline
        Write-InstallLog "OK" "`u{2713} deploy.yaml 路径已替换"
    }

    Write-InstallLog "INFO" "  PythonExecutable: $pyPath"
    Write-InstallLog "INFO" "  GitExecutable: $gitPath"
    Write-InstallLog "INFO" "  AdbExecutable: $adbPath"
    Complete-Step -Icon "`u{2714}`u{FE0F}" "deploy.yaml 已配置"
}

function New-Launcher {
    Start-Step "正在生成启动脚本..."

    Write-InstallLog "INFO" "  Conda: $CondaBin"
    Write-InstallLog "INFO" "  ALAS 目录: $AlasDir"

    $runAlas = @"
@echo off
chcp 65001 >nul
set "ALAS_DIR=$AlasDir"
set "CONDA_BIN=$CondaBin"
set "PYTHONUTF8=1"
cd /d "%ALAS_DIR%"
start "" http://127.0.0.1:22267
"%CONDA_BIN%" run -n alas --cwd "%ALAS_DIR%" --no-capture-output python gui.py
"@

    $targetDir = $ScriptOutDir
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    Set-Content -Path "$targetDir\run_alas.bat" -Value $runAlas
    Write-InstallLog "OK" "`u{2713} 启动脚本已生成: $targetDir\run_alas.bat"
    Complete-Step -Icon "`u{2714}`u{FE0F}" "启动脚本已生成: $targetDir\run_alas.bat"
}

function Enable-ScheduledTask {
    Start-Step "正在配置计划任务自启..."

    $taskName = "ALAS"
    $launcherPath = Join-Path $ScriptOutDir "run_alas.bat"
    $taskExists = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($taskExists) {
        Write-InstallLog "EXEC" "`u{25B6} 移除已有计划任务: $taskName"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    Write-InstallLog "EXEC" "`u{25B6} Register-ScheduledTask $taskName"
    $action = New-ScheduledTaskAction -Execute $launcherPath -WorkingDirectory $ScriptOutDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
            -Description "Start AzurLaneAutoScript at logon" -Force -ErrorAction Stop | Out-Null
        Write-InstallLog "OK" "`u{2713} 计划任务 $taskName 已创建"
        Complete-Step -Icon "`u{2714}`u{FE0F}" "计划任务已创建：用户登录时启动 ALAS"
    } catch {
        Write-InstallLog "WARNING" "计划任务创建失败: $_"
        Complete-Step -Icon "`u{26A0}`u{FE0F}" "计划任务创建失败，请手动配置" "Yellow"
    }
}

function Stop-AlasProcess {
    param([string]$AlasDir)

    Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and
        ($_.CommandLine -like "*gui.py*" -or $_.CommandLine -like "*AzurLaneAutoScript*") -and
        $_.CommandLine -like "*$AlasDir*"
    } | ForEach-Object {
        try {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
            Write-InstallLog "INFO" "已停止 ALAS 进程 PID=$($_.ProcessId)"
        } catch {
            Write-InstallLog "WARNING" "无法停止 PID=$($_.ProcessId): $_"
        }
    }
}

function Write-Completion {
    Write-Host ""
    Write-Host "`u{1F680}  ALAS 已经完成安装，请通过 http://${NetIP}:22267 访问 WEBUI" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────────────────"
    Write-Host "  `u{1F4A1}  ALAS已安装到:  $AlasDir" -ForegroundColor Blue
    if ($SkipService) {
        Write-Host "  `u{1F4A1}  手动启动:  $ScriptOutDir\run_alas.bat" -ForegroundColor Cyan
    }
    Write-Host ""
}

function Invoke-Uninstall {
    Write-Host ""
    Write-Warn "即将执行 ALAS 卸载，将删除以下内容："
    Write-Warn "  - Conda 虚拟环境 (alas)"
    Write-Warn "  - 计划任务 (ALAS)"
    Write-Warn "  - ALAS 目录: $InstallDir"
    Write-Warn "  - 启动脚本: $ScriptOutDir\run_alas.bat"
    Write-Host "  `u{1F4A1}  Git, ADB, Miniforge 及相关依赖不会被删除" -ForegroundColor Green
    Write-Host ""

    Write-InstallLog "WARNING" "等待确认卸载"
    if ($UninstallYes) {
        Write-InstallLog "INFO" "已通过 --yes 自动确认卸载"
    } else {
        $confirm = Read-Host "  确认继续吗？ [yes/N]"
        if ($confirm -notmatch "^(yes|YES)$") {
            Write-InstallLog "INFO" "卸载取消"
            Write-Host "  `u{1F4A1} 已取消卸载"
            exit 0
        }
        Write-InstallLog "INFO" "已确认卸载"
    }
    Write-Host ""

    Start-Step "正在停止 ALAS 进程..."
    Stop-AlasProcess -AlasDir $InstallDir
    Complete-Step -Icon "`u{2714}`u{FE0F}" "ALAS 进程已停止"

    Start-Step "正在移除计划任务..."
    $task = Get-ScheduledTask -TaskName "ALAS" -ErrorAction SilentlyContinue
    if ($task) {
        Write-InstallLog "EXEC" "`u{25B6} Unregister-ScheduledTask ALAS"
        Unregister-ScheduledTask -TaskName "ALAS" -Confirm:$false -ErrorAction SilentlyContinue
        Write-InstallLog "OK" "`u{2713} 计划任务已移除"
        Complete-Step -Icon "`u{2714}`u{FE0F}" "计划任务已移除"
    } else {
        Complete-Step -Icon "`u{1F4A1}" "未检测到计划任务，跳过" "Green"
    }

    Start-Step "正在清理 Conda 虚拟环境..."
    $foundConda = Find-CondaExe
    if ($foundConda) {
        Write-InstallLog "INFO" "使用 conda: $foundConda"

        try {
            $envInfo = & $foundConda env list --json 2>$null | ConvertFrom-Json
            $alasExists = $envInfo.envs | Where-Object { Split-Path $_ -Leaf -eq "alas" }
        } catch {
            $envList = & $foundConda env list 2>$null
            $alasExists = $envList -match "^alas "
        }

        if ($alasExists) {
            Write-InstallLog "EXEC" "`u{25B6} conda clean -a -y"
            try {
                & $foundConda clean -a -y 2>&1 | Out-LogFile
            } catch {
                Write-InstallLog "WARNING" "conda clean 失败，继续移除环境"
            }
            Write-InstallLog "EXEC" "`u{25B6} conda env remove -n alas -y"
            try {
                & $foundConda env remove -n alas -y 2>&1 | Out-LogFile
            } catch {
                $envsPath = & $foundConda info --base 2>$null
                if ($envsPath -and (Test-Path "$envsPath\envs\alas")) {
                    Remove-Item "$envsPath\envs\alas" -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            Write-InstallLog "OK" "`u{2713} Conda 环境已移除"
        } else {
            Write-InstallLog "INFO" "未检测到 alas 环境，跳过"
        }
        Complete-Step -Icon "`u{2714}`u{FE0F}" "虚拟环境已清理"
    } else {
        Complete-Step -Icon "`u{1F4A1}" "未检测到 Conda，跳过虚拟环境清理" "Green"
    }

    Start-Step "正在删除启动脚本..."
    if (Test-Path "$ScriptOutDir\run_alas.bat") {
        Write-InstallLog "EXEC" "`u{25B6} Remove-Item $ScriptOutDir\run_alas.bat"
        Remove-Item "$ScriptOutDir\run_alas.bat" -Force -ErrorAction SilentlyContinue
        Complete-Step -Icon "`u{2714}`u{FE0F}" "启动脚本已删除"
    } else {
        Complete-Step -Icon "`u{1F4A1}" "启动脚本不存在，跳过" "Green"
    }

    Start-Step "正在删除 ALAS 目录..."
    if (Test-Path $InstallDir) {
        $originUrl = ""
        if (Test-Path "$InstallDir\.git") {
            try {
                $originUrl = git -C "$InstallDir" remote get-url origin 2>$null
            } catch { $null = $_ }
        }

        if ($originUrl -match 'github\.com[:/]+LmeSzinc/AzurLaneAutoScript(\.git)?$') {
            Write-InstallLog "OK" "git 远程 URL 验证通过: $originUrl"
        } elseif (-not $originUrl) {
            Write-InstallLog "WARNING" "目录中没有 .git 信息，可能不是完整的 ALAS 仓库，但仍继续删除"
        } else {
            Complete-Step -Icon "`u{274C}" "目录 $InstallDir 是其他 git 仓库 ($originUrl)，为避免误删将终止卸载" "Red"
            exit 1
        }

        Write-InstallLog "EXEC" "`u{25B6} Remove-Item $InstallDir"
        Set-Location $env:USERPROFILE -ErrorAction SilentlyContinue
        Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Complete-Step -Icon "`u{2714}`u{FE0F}" "目录已删除"
    } else {
        Complete-Step -Icon "`u{1F4A1}" "ALAS 目录已不存在，跳过" "Green"
    }

    if (-not $KeepLog) {
        $logFiles = Get-ChildItem "$env:TEMP\alas_install_$pid*.log" -ErrorAction SilentlyContinue
        foreach ($f in $logFiles) {
            Write-InstallLog "INFO" "清理日志文件: $($f.FullName)"
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host ""
    Write-Host "`u{2714}`u{FE0F}  ALAS 卸载完成" -ForegroundColor Green
    Write-Host ""
}

function Main {
    if ($Debug) {
        Write-Host "  `u{2699}`u{FE0F}  检测到 --debug, 进入调试模式" -ForegroundColor Cyan
        Write-Host "  `u{2699}`u{FE0F}  日志将实时输出至终端" -ForegroundColor Cyan
        Write-Host ""
    }

    if ($Uninstall) {
        Test-Prerequisite
        Get-SystemInfo
        Show-Header
        Invoke-Uninstall
        exit 0
    }

    Test-Prerequisite
    Get-SystemInfo
    Show-Header

    Install-Miniforge
    Install-GitADB
    Sync-ALASRepo
    Initialize-CondaEnv
    Set-Deploy
    New-Launcher

    if ($CreateService) {
        Enable-ScheduledTask
    }

    Write-Completion
    if (-not $KeepLog) {
        $logFiles = Get-ChildItem "$env:TEMP\alas_install_$pid*.log" -ErrorAction SilentlyContinue
        foreach ($f in $logFiles) {
            Write-InstallLog "INFO" "安装完成，清理日志文件: $($f.FullName)"
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-InstallLog "INFO" "安装完成，日志已保存至: $LogFile"
        Write-Host "  `u{1F4A1}  日志已保存至：$LogFile"
    }
    $global:LASTEXITCODE = 0
}

Main
