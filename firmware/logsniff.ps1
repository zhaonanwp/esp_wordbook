$ErrorActionPreference = 'Stop'
$p = New-Object System.IO.Ports.SerialPort 'COM3',115200,'None',8,'One'
$p.ReadTimeout = 1000
$p.NewLine = "`n"
$p.Open()
Start-Sleep -Seconds 1
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.Seconds -lt 20) {
    try {
        $line = $p.ReadLine()
        Write-Output $line
    } catch [System.TimeoutException] { }
}
$p.Close()
