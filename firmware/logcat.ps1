param([string]$Port = 'COM3', [int]$Seconds = 10)

# 抓 USB Serial JTAG 上的启动日志。
# 打开端口本身会让芯片复位（DTR/RTS 跳变），所以能从头读到 bootloader 输出。
# ReadLine() 会漏掉没有换行的碎片，这里直接按原始字节读。

$ErrorActionPreference = 'Stop'
$p = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
$p.ReadTimeout = 500
# USB Serial JTAG 的线义：DTR -> GPIO0（拉低进下载模式），RTS -> EN（拉低复位）。
# DTR 保持 false，复位脉冲打完之后芯片是从正常启动走的；
# 两个都置 true 会把芯片按在 ROM 下载模式里，只吐一行 ESP-ROM 然后静默。
$p.DtrEnable = $false
$p.RtsEnable = $false
$p.Open()
Start-Sleep -Milliseconds 200
$p.RtsEnable = $true
Start-Sleep -Milliseconds 200
$p.RtsEnable = $false
# 不要 DiscardInBuffer：复位之后这一刻的启动日志正是要看的内容。

$deadline = (Get-Date).AddSeconds($Seconds)
$buffer = New-Object System.Collections.Generic.List[byte]
while ((Get-Date) -lt $deadline) {
    try {
        $count = $p.BytesToRead
        if ($count -gt 0) {
            $chunk = New-Object byte[] $count
            [void]$p.Read($chunk, 0, $count)
            $buffer.AddRange($chunk)
        } else {
            Start-Sleep -Milliseconds 50
        }
    } catch [System.TimeoutException] { }
}
$p.Close()

$text = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray())
Write-Output ("bytes={0}" -f $buffer.Count)
Write-Output $text
