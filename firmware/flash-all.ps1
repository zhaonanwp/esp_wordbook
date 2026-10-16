param([string]$Port = '')

# 一次连接把固件 + 词表镜像全烧完（避免分两次插线）
#   .\flash-all.ps1            # 自动找端口
#   .\flash-all.ps1 -Port COM3

$ErrorActionPreference = 'Stop'

$Env:Path = ($Env:Path -split ';' | Where-Object { $_ -and $_ -notmatch 'msys|mingw|Git' }) -join ';'
Remove-Item Env:MSYSTEM -ErrorAction SilentlyContinue

. 'C:\Espressif\tools\Microsoft.v5.5.4.PowerShell_profile.ps1'
Set-Location $PSScriptRoot

$bootloader = 'bootloader\bootloader.bin'
$partitions = 'partition_table\partition-table.bin'
$otadata    = 'ota_data_initial.bin'
$app        = 'wordcard.bin'
$wordbook   = 'wordbook.bin'

foreach ($f in @($bootloader, $partitions, $otadata, $app)) {
    if (-not (Test-Path "build\$f")) { throw "build\ 里缺 $f —— 先跑 .\build.ps1 build" }
}
if (-not (Test-Path "build\$wordbook")) {
    throw "build\ 里缺 $wordbook —— 先跑 .\flash-wordbook.ps1 -Action gen"
}

$portArg = @()
if ($Port -ne '') { $portArg = @('-p', $Port) }

python -m esptool --chip esp32s3 @portArg -b 460800 `
    --before default_reset --after hard_reset `
    write_flash --flash_mode dio --flash_freq 80m --flash_size 16MB `
    0x0       "build\$bootloader" `
    0x8000    "build\$partitions" `
    0xd000    "build\$otadata" `
    0x100000  "build\$app" `
    0x800000  "build\$wordbook"

if ($LASTEXITCODE -ne 0) { throw "烧录失败" }
Write-Host "固件 + 词表都烧完了，设备已重启"
