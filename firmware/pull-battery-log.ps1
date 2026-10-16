param(
    [string]$Port = '',
    [string]$Out = 'battery-log.csv',
    [int]$Baud = 460800
)

# storage 分区（0x800000）整块读回来，扫出设备侧写的放电记录，写成 CSV。
#
#   .\pull-battery-log.ps1
#   .\pull-battery-log.ps1 -Port COM3 -Baud 115200
#
# 分块读：这块板的 USB-Serial/JTAG 一次性读 8MB 会在 1MB 出头就断流
# ("Packet content transfer stopped")，所以每次只读 1MB，失败重试，第二次起降速。
#
# 注意：esptool 会把芯片复位进下载模式，读期间设备是关机的；读完 hard_reset 恢复。
# 重跑 flash-wordbook.ps1 会重写整个 storage 分区，日志文件一起没。

$ErrorActionPreference = 'Stop'

# Git Bash / MSYS 的 mingw 会让 idf_tools.py 直接拒绝运行，这里清掉 PATH。
$Env:Path = ($Env:Path -split ';' | Where-Object { $_ -and $_ -notmatch 'msys|mingw|Git' }) -join ';'
Remove-Item Env:MSYSTEM -ErrorAction SilentlyContinue

$root = $PSScriptRoot
$dump = Join-Path $root 'build\battery-dump.bin'
$chunkDir = Join-Path $root 'build\battery-dump'
$base = 0x800000
$chunkSize = 0x100000
$chunks = 8   # storage 分区 8MB，见 partitions/wordcard-16m.csv

. 'C:\Espressif\tools\Microsoft.v5.5.4.PowerShell_profile.ps1'
Set-Location $root

$portArg = @()
if ($Port -ne '') { $portArg = @('-p', $Port) }

# 每次整轮重读：留着上次的分块会读到旧镜像。
if (Test-Path $chunkDir) { Remove-Item (Join-Path $chunkDir '*.bin') }
New-Item -ItemType Directory -Force -Path $chunkDir | Out-Null

function Invoke-Esptool([string[]]$esptoolArgs, [string]$logPath) {
    # esptool 的报错走 stderr，$ErrorActionPreference='Stop' 下会被当成终止错误，
    # 这里临时放行，靠退出码和落盘长度判断成败。
    $ErrorActionPreference = 'Continue'
    & python -m esptool @esptoolArgs *> $logPath
    $code = $LASTEXITCODE
    return $code
}

for ($i = 0; $i -lt $chunks; $i++) {
    $offset = $base + $i * $chunkSize
    $piece = Join-Path $chunkDir ("part_{0:d2}.bin" -f $i)
    $log = Join-Path $chunkDir ("esptool_{0:d2}.log" -f $i)

    $ok = $false
    for ($try = 1; $try -le 3 -and -not $ok; $try++) {
        $tryBaud = if ($try -eq 1) { $Baud } else { 115200 }
        Write-Host ("读 0x{0:X} +0x{1:X}（第 {2}/{3} 块，第 {4} 次，{5}）" -f `
            $offset, $chunkSize, ($i + 1), $chunks, $try, $tryBaud)
        $toolArgs = @('--chip', 'esp32s3') + $portArg + @(
            '-b', "$tryBaud",
            '--before', 'default_reset', '--after', 'no_reset',
            'read_flash', ("0x{0:X}" -f $offset), ("0x{0:X}" -f $chunkSize), $piece
        )
        $null = Invoke-Esptool $toolArgs $log
        $ok = (Test-Path $piece) -and ((Get-Item $piece).Length -eq $chunkSize)
        if (-not $ok) { Start-Sleep -Seconds 2 }
    }
    if (-not $ok) { throw "第 $($i + 1) 块读失败，看 $chunkDir\esptool_$($i.ToString('D2')).log，或换根线/换个 USB 口" }
}

Write-Host "拼成整块 dump: $dump"
$stream = [System.IO.File]::Create($dump)
try {
    for ($i = 0; $i -lt $chunks; $i++) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $chunkDir ("part_{0:d2}.bin" -f $i)))
        $stream.Write($bytes, 0, $bytes.Length)
    }
} finally {
    $stream.Close()
}

# 读的时候停在下载模式，这里复位让它继续跑（日志能接着攒）。
$resetArgs = @('--chip', 'esp32s3') + $portArg +
    @('--before', 'no_reset', '--after', 'hard_reset', 'chip_id')
$null = Invoke-Esptool $resetArgs (Join-Path $chunkDir 'reset.log')

$ErrorActionPreference = 'Continue'   # 解析脚本没找到记录时会写 stderr
& python (Join-Path $root 'parse-battery-log.py') $dump -o (Join-Path $root $Out)
if ($LASTEXITCODE -ne 0) { throw "解析失败" }
