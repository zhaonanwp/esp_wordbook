# 单词机工程的构建入口：把参数原样转给 idf.py
#   .\build.ps1 set-target esp32s3
#   .\build.ps1 build
#   .\build.ps1 flash monitor
#
# 两个坑：
#   1) idf_tools.py 只要 PATH 里出现 msys/mingw 就判定 "MSys/Mingw is not supported" 并拒绝，
#      从 Git Bash 调 PowerShell 时 Git 的 mingw64/bin 会继承过来，所以先滤掉。
#   2) 直接 dot-source esp-idf\export.ps1 在这里不通，eim 装的是自己那份激活脚本。
$Env:Path = ($Env:Path -split ';' | Where-Object { $_ -and $_ -notmatch 'msys|mingw|Git' }) -join ';'
Remove-Item Env:MSYSTEM -ErrorAction SilentlyContinue

. 'C:\Espressif\tools\Microsoft.v5.5.4.PowerShell_profile.ps1'
Set-Location $PSScriptRoot
idf.py @args
