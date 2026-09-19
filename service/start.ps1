#Requires -Version 5.1
<#
.SYNOPSIS
    Windows PowerShell 一键启动 deskbot-server（等价于 start.sh，不依赖 bash）。
    在 service 目录执行：  .\start.ps1
    若被执行策略拦截：      powershell -ExecutionPolicy Bypass -File .\start.ps1

.DESCRIPTION
    自动：校验 Python(>=3.11, 默认 py -3.12) → 建 .venv → 装 CPU torch + 依赖 →
    下载模型(ASR ~900MB / 人脸 / Silero VAD) → 起主服务(:9000)，可选独立 Web(:5050)。

.ENV / 参数（均可环境变量或参数传入，参数优先）
    -PythonVersion      目标 Python 主次版本，默认 "3.12"（避开 3.13 无 torch CPU 包）
    -PythonBin          显式 Python 可执行文件，跳过自动查找
    -SkipSetup          跳过 venv/依赖安装，仅启动（要求 .venv 已就绪）
    -FastStart          跳过 pip 安装（.venv 须已完整）；依赖就绪时也会自动跳过
    -SkipModelDownload  跳过模型下载（ASR/Silero 缺失则直接报错退出）
    -SkipSystemCheck    跳过 ffmpeg 等系统依赖警告
    -UseCpuTorch        安装 CPU 版 torch（默认 $true）
    -StartWeb           额外启动独立 Web 进程(:5050)；默认合并进主服务 :9000
    -WebPort            独立 Web 端口，默认 5050
    -NoOpenBrowser      启动后不自动打开浏览器（默认自动开 http://localhost:9000/）
#>
param(
    [string]$PythonVersion   = "3.12",
    [string]$PythonBin       = "",
    [switch]$SkipSetup,
    [switch]$FastStart,
    [switch]$SkipModelDownload,
    [switch]$SkipSystemCheck,
    [bool]$UseCpuTorch       = $true,
    [switch]$StartWeb,
    [int]$WebPort            = 5050,
    [switch]$NoOpenBrowser
)

# 允许用环境变量覆盖（参数优先于环境变量）
if ($env:PYTHON_VERSION)            { $PythonVersion = $env:PYTHON_VERSION }
if ($env:PYTHON_BIN)                { $PythonBin = $env:PYTHON_BIN }
if ($env:SKIP_SETUP -eq '1')        { $SkipSetup = $true }
if ($env:FAST_START -eq '1')        { $FastStart = $true }
if ($env:SKIP_MODEL_DOWNLOAD -eq '1') { $SkipModelDownload = $true }
if ($env:SKIP_SYSTEM_CHECK -eq '1') { $SkipSystemCheck = $true }
if ($env:USE_CPU_TORCH)             { $UseCpuTorch = ($env:USE_CPU_TORCH -ne '0') }
if ($env:DESKBOT_START_WEB -eq '1') { $StartWeb = $true }
if ($env:DESKBOT_WEB_PORT)          { $WebPort = [int]$env:DESKBOT_WEB_PORT }
if ($env:DESKBOT_NO_OPEN_BROWSER -eq '1') { $NoOpenBrowser = $true }

$ROOT = $PSScriptRoot
# 强制切到脚本所在目录（service/）作为工作目录：
# deskbot_server 默认按 CWD 解析 config.yaml / 相对模型路径，
# 若从其他目录执行 -File 启动会因找不到 config.yaml 而退出。
Set-Location $ROOT
$VENV = Join-Path $ROOT ".venv"
$VPY  = Join-Path $VENV "Scripts\python.exe"

function Write-Step($m) { Write-Host "[setup] $m" -ForegroundColor Cyan }
function Write-Warn($m) { Write-Host "[warn] $m" -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "[error] $m" -ForegroundColor Red }

# ---------- Python 查找 / 校验 ----------
function Test-PyVersion($exe, $major, $minor) {
    $out = & $exe -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $false }
    $mv = [version]($out -replace '^(\d+\.\d+).*', '$1')
    return ($mv -ge [version]"$major.$minor")
}

function Find-Python($reqMM) {
    $maj = $reqMM.Split('.')[0]; $min = $reqMM.Split('.')[1]
    $probes = @(
        @('py', "-$reqMM"),
        @('py', "-$maj.$min"),
        @('py', "-$maj"),
        @('py', '-3'),
        @('python', '')
    )
    foreach ($p in $probes) {
        $cmd = $p[0]; $arg = $p[1]
        try {
            if ($arg) { $exe = & $cmd $arg -c "import sys; print(sys.executable)" 2>$null }
            else      { $exe = & $cmd    -c "import sys; print(sys.executable)" 2>$null }
        } catch { continue }
        if ($LASTEXITCODE -eq 0 -and $exe) {
            $exe = $exe.Trim()
            if (Test-PyVersion $exe 3 11) { return $exe }
        }
    }
    return $null
}

if ($PythonBin) {
    if (-not (Test-PyVersion $PythonBin 3 11)) {
        Write-Err "PYTHON_BIN=$PythonBin 不满足 Python >= 3.11"
        exit 1
    }
    $PYTHON_BIN = $PythonBin
} else {
    $PYTHON_BIN = Find-Python $PythonVersion
    if (-not $PYTHON_BIN) {
        Write-Err "未找到 Python >= 3.11。请安装 Python 3.12（https://www.python.org/downloads/），或 -PythonBin 显式指定。"
        exit 1
    }
}
Write-Host "Python: $PYTHON_BIN" -ForegroundColor Green

# ---------- 系统依赖检查 ----------
if (-not $SkipSystemCheck) {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        Write-Warn "未检测到 ffmpeg；opus 转码可能失败。安装: winget install ffmpeg（或设 -SkipSystemCheck 跳过）"
    }
}

# ---------- 建 venv + 装依赖 ----------
function Venv-Ready {
    if (-not (Test-Path $VPY)) { return $false }
    & $VPY -c "import numpy, websockets, yaml, webrtcvad, openai, opuslib_next, torch, torchaudio, funasr, croniter, fastapi, uvicorn, deskbot_server" 2>$null
    return ($LASTEXITCODE -eq 0)
}

if (-not $SkipSetup) {
    if ($FastStart -and (Venv-Ready)) {
        Write-Step "检测到 venv 依赖已就绪，跳过 pip 安装（等同 FastStart）。"
    } else {
        if ($FastStart) {
            Write-Err "FastStart 但 .venv 依赖不完整，请先完整执行一次 .\start.ps1（不设 FastStart）。"
            exit 1
        }
        Write-Step "准备 Python 虚拟环境 (.venv) ..."
        if (-not (Test-Path $VENV)) {
            & $PYTHON_BIN -m venv $VENV
            if ($LASTEXITCODE -ne 0) { Write-Err "创建 .venv 失败，请确认 Python 自带 venv 模块。"; exit 1 }
        }
        if (-not (Test-Path $VPY)) { Write-Err "创建 .venv 失败。"; exit 1 }

        # pip 镜像（清华），失败则退回环境变量
        & $VPY -m pip install --upgrade pip 2>&1 | Out-Null
        & $VPY -m pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple 2>$null
        if ($LASTEXITCODE -ne 0) { $env:PIP_INDEX_URL = "https://pypi.tuna.tsinghua.edu.cn/simple" }

        if ($UseCpuTorch) {
            Write-Step "安装 CPU 版 torch/torchaudio（避免 CUDA 包）..."
            & $VPY -m pip install torch==2.2.2 torchaudio==2.2.2 --index-url https://download.pytorch.org/whl/cpu --default-timeout=1000
            if ($LASTEXITCODE -ne 0) { Write-Err "torch 安装失败：请确认 Python >= 3.11 且能访问网络。"; exit 1 }
        }
        Write-Step "安装项目依赖 (requirements.txt) ..."
        & $VPY -m pip install -r (Join-Path $ROOT requirements.txt) --default-timeout=1000
        if ($LASTEXITCODE -ne 0) { Write-Err "依赖安装失败。"; exit 1 }
        & $VPY -m pip install -e $ROOT --no-deps
        if ($LASTEXITCODE -ne 0) { Write-Err "pip install -e . 失败。"; exit 1 }

        # 可选 miloco-miot wheel
        $miot = Get-ChildItem (Join-Path $ROOT "src/deskbot_server/iotctl/wheels/miloco_miot-*.whl") -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($miot) {
            Write-Step "安装可选 miloco-miot: $($miot.Name)"
            & $VPY -m pip install --no-deps $miot.FullName
        } else {
            Write-Step "未找到 miloco-miot wheel（米家可选，可忽略）。"
        }
    }
} else {
    Write-Step "SkipSetup=1，跳过 venv/依赖安装。"
    if (-not (Test-Path $VPY)) {
        Write-Err "未找到 .venv，请先完整执行一次 .\start.ps1（不要设 SkipSetup）。"
        exit 1
    }
}

# ---------- .env ----------
$envFile = Join-Path $ROOT ".env"
$envExample = Join-Path $ROOT ".env.example"
if (-not (Test-Path $envFile) -and (Test-Path $envExample)) {
    Copy-Item $envExample $envFile
    Write-Step "已从 .env.example 创建 .env —— 请编辑并填写 ARK_API_KEY（火山方舟，语音对话必填）"
}
# 把 .env 注入当前进程环境
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#') -and $line -match '^([^=]+)=(.*)$') {
            $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
            if (-not (Test-Path "env:$k")) { Set-Item -Path "env:$k" -Value $v }
        }
    }
    $hasKey = ($env:ARK_API_KEY -or $env:LLM_API_KEY -or $env:VOLCENGINE_API_KEY -or $env:DASHSCOPE_API_KEY -or $env:QWEN_API_KEY)
    if (-not $hasKey) { Write-Warn "未设置 ARK_API_KEY（等），语音对话将无法调用大模型；请编辑 .env 后重启。" }
}

# ---------- 模型下载 ----------
$ASR_DIR  = Join-Path $ROOT "models\SenseVoiceSmall"
$FACE_DIR = Join-Path $ROOT "models\mediapipe"
$FACE_FILE = Join-Path $FACE_DIR "face_landmarker.task"
$FACE_URL  = "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task"
$SIL_DIR  = Join-Path $ROOT "models\silero_vad"
$SIL_FILE = Join-Path $SIL_DIR "silero_vad.onnx"
$SIL_URL   = "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx"

function Test-AsrReady { & $VPY (Join-Path $ROOT "scripts/check_asr_model.py") $ASR_DIR 2>$null; return ($LASTEXITCODE -eq 0) }

if ($SkipModelDownload) {
    Write-Step "SkipModelDownload=1，跳过模型下载检查。"
    if (-not (Test-AsrReady))    { Write-Err "ASR 模型缺失: $ASR_DIR"; exit 1 }
    if (-not (Test-Path $SIL_FILE)) { Write-Err "Silero VAD 模型缺失: $SIL_FILE"; exit 1 }
} else {
    # ASR (SenseVoiceSmall ~900MB)
    if (Test-AsrReady) {
        Write-Step "ASR 模型已就绪: $ASR_DIR"
    } else {
        Write-Step "下载 SenseVoiceSmall ASR 模型（约 900MB，首次较慢）..."
        & $VPY -m pip install -U modelscope 2>&1 | Out-Null
        & $VPY (Join-Path $ROOT "scripts/download_model.py")
        if ($LASTEXITCODE -ne 0) { Write-Err "ASR 模型下载失败。"; exit 1 }
    }
    # 量化 ONNX（首次约 1 分钟，可选）
    $asrPt = Join-Path $ASR_DIR "model.pt"
    $asrOnnx = Join-Path $ASR_DIR "model_quant.onnx"
    if ((Test-Path $asrPt) -and -not (Test-Path $asrOnnx)) {
        Write-Step "导出 ASR 量化 ONNX（model_quant.onnx，首次约 1 分钟）..."
        & $VPY (Join-Path $ROOT "scripts/export_asr_quant_onnx.py") $ASR_DIR
        if ($LASTEXITCODE -ne 0) { Write-Warn "量化 ONNX 导出失败，将回退 PyTorch model.pt 推理。" }
    }
    # 人脸 (MediaPipe)
    if (Test-Path $FACE_FILE) {
        Write-Step "人脸模型已就绪: $FACE_FILE"
    } else {
        Write-Step "下载 MediaPipe 人脸模型（约 3.6MB）..."
        New-Item -ItemType Directory -Force -Path $FACE_DIR | Out-Null
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -L --fail -o $FACE_FILE $FACE_URL
        } else {
            try { Invoke-WebRequest -Uri $FACE_URL -OutFile $FACE_FILE -ErrorAction Stop } catch { Write-Warn "人脸模型下载失败（camera_frame 人脸功能可能不可用）。" }
        }
    }
    # Silero VAD
    if (Test-Path $SIL_FILE) {
        Write-Step "Silero VAD 模型已就绪: $SIL_FILE"
    } else {
        Write-Step "下载 Silero VAD 模型（约 2.3MB）..."
        New-Item -ItemType Directory -Force -Path $SIL_DIR | Out-Null
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -L --fail -o $SIL_FILE $SIL_URL
        } else {
            try { Invoke-WebRequest -Uri $SIL_URL -OutFile $SIL_FILE -ErrorAction Stop } catch { Write-Err "Silero VAD 下载失败，/asr_chat 将无法接入。"; exit 1 }
        }
    }
}

# ---------- 启动 ----------
$webProc = $null
try {
    if ($StartWeb) {
        Write-Step "额外启动独立 Web 进程 0.0.0.0:$WebPort（主服务 :9000 已内置控制台；通常无需再开）"
        $env:DESKBOT_WEB_HOST = "0.0.0.0"
        $env:DESKBOT_WEB_PORT = $WebPort
        $webProc = Start-Process -FilePath $VPY -ArgumentList "-m", "deskbot_server.web" -PassThru -WindowStyle Normal
    } else {
        Write-Step "控制台已合并进主 FastAPI（默认 :9000）；需要独立进程时加 -StartWeb"
    }

    # 启动后自动打开 Web 控制台（等待端口就绪再开，避免连接被拒）
    if (-not $NoOpenBrowser) {
        $consoleUrl = if ($StartWeb) { "http://localhost:$WebPort/" } else { "http://localhost:9000/" }
        $openPort   = if ($StartWeb) { $WebPort } else { 9000 }
        Write-Step "启动后将自动打开 Web 控制台: $consoleUrl（可用 -NoOpenBrowser 关闭）"
        $pollerCmd = "try { `$d=(Get-Date).AddSeconds(45); while((Get-Date)-lt`$d){ try { if (Get-NetTCPConnection -LocalPort $openPort -ErrorAction SilentlyContinue) { Start-Process '$consoleUrl'; exit } } catch {}; Start-Sleep -Seconds 1 } } catch {}"
        Start-Process -FilePath "powershell" -ArgumentList "-NoProfile", "-Command", $pollerCmd -WindowStyle Hidden
    }

    Write-Host "[1/1] 启动 deskbot-server ..." -ForegroundColor Green
    & $VPY -m deskbot_server
} finally {
    if ($webProc -and -not $webProc.HasExited) {
        Write-Step "停止 Web 进程 ..."
        Stop-Process -Id $webProc.Id -Force
    }
}
