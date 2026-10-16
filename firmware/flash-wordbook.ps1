param(
    [ValidateSet('gen', 'flash', 'all')]
    [string]$Action = 'all',
    [string]$Port = ''
)

# 词表 -> FAT 镜像 -> storage 分区（0x800000）
#
#   .\flash-wordbook.ps1            # 生成 + 烧录（自动找端口）
#   .\flash-wordbook.ps1 -Action gen
#   .\flash-wordbook.ps1 -Port COM3
#
# 只动 storage 数据分区，不重编固件、不动 app 分区。

$ErrorActionPreference = 'Stop'

# Git Bash / MSYS 的 mingw 会让 idf_tools.py 直接拒绝运行，这里清掉 PATH。
$Env:Path = ($Env:Path -split ';' | Where-Object { $_ -and $_ -notmatch 'msys|mingw|Git' }) -join ';'
Remove-Item Env:MSYSTEM -ErrorAction SilentlyContinue

$root = $PSScriptRoot
$dataDir = Join-Path $root 'data'
$image = Join-Path $root 'build\wordbook.bin'
$storageOffset = '0x800000'
$storageSize = 8388608   # 与 partitions/wordcard-16m.csv 里 storage 分区的 0x800000 对应
# 本机 ESP-IDF 路径从环境变量取（激活脚本会设这两个）；没激活就先把下面两行改成你本机的绝对路径。
$genScript = if ($env:IDF_PATH) {
    Join-Path $env:IDF_PATH 'components\fatfs\wl_fatfsgen.py'
} else {
    throw 'IDF_PATH 没设：先 dot-source 你本机的 ESP-IDF 激活脚本，或把 $genScript 指到 components/fatfs/wl_fatfsgen.py'
}
$python = if ($env:IDF_PYTHON_ENV_PATH) { Join-Path $env:IDF_PYTHON_ENV_PATH 'Scripts\python.exe' } else { 'python' }

if (-not (Test-Path (Join-Path $dataDir 'words.tsv'))) {
    throw "找不到 $dataDir\words.tsv"
}

if ($Action -in @('gen', 'all')) {
    Write-Host "生成 WL-FAT 镜像: $dataDir -> $image"
    New-Item -ItemType Directory -Force -Path (Split-Path $image) | Out-Null
    & $python $genScript $dataDir `
        --output_file $image `
        --partition_size $storageSize `
        --sector_size 512 `
        --fat_type 16 `
        --long_name_support
    if ($LASTEXITCODE -ne 0) { throw "wl_fatfsgen.py 失败" }
    Write-Host ("镜像大小 {0} 字节" -f (Get-Item $image).Length)
}

if ($Action -in @('flash', 'all')) {
    . 'C:\Espressif\tools\Microsoft.v5.5.4.PowerShell_profile.ps1'
    Set-Location $root

    $portArg = @()
    if ($Port -ne '') { $portArg = @('-p', $Port) }

    & python -m esptool --chip esp32s3 @portArg -b 460800 `
        --before default_reset --after hard_reset `
        write_flash $storageOffset $image
    if ($LASTEXITCODE -ne 0) { throw "烧录失败" }
    Write-Host "词表已烧到 $storageOffset，设备重启后生效"
}
