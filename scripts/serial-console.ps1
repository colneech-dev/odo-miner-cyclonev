<#
  serial-console.ps1 — minimal interactive serial terminal for the board's
  onboard CH340N USB-UART (J4 mini-USB port -> HPS UART0, 115200 8N1).
  Avoids needing PuTTY/minicom installed.

  Usage:
    .\serial-console.ps1                 # auto-detects a CH340 COM port
    .\serial-console.ps1 -Port COM22     # explicit port

  Exit: press Ctrl+] (like telnet) to close the session.
#>
param([string]$Port, [int]$Baud = 115200)

if (-not $Port) {
    $dev = Get-CimInstance -ClassName Win32_PnPEntity | Where-Object { $_.Name -match 'CH340.*\((COM\d+)\)' } | Select-Object -First 1
    if ($dev -and $dev.Name -match '\((COM\d+)\)') { $Port = $Matches[1] }
}
if (-not $Port) { throw "Could not auto-detect a CH340 COM port. Pass -Port COM<N> explicitly (check Device Manager)." }

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 100
$sp.WriteTimeout = 1000
$sp.Open()

Write-Host "=== connected to $Port @ $Baud 8N1 — Ctrl+] to exit ===" -ForegroundColor Cyan

try {
    while ($true) {
        # drain any waiting serial input
        try {
            while ($sp.BytesToRead -gt 0) {
                $b = $sp.ReadByte()
                if ($b -ge 0) { [Console]::Out.Write([char]$b) }
            }
        } catch [System.TimeoutException] { }

        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            # Ctrl+] = ASCII 0x1D, our exit hotkey
            if ($key.Key -eq [ConsoleKey]::Oem6 -and $key.Modifiers -eq [ConsoleModifiers]::Control) { break }
            $ch = $key.KeyChar
            if ($key.Key -eq [ConsoleKey]::Enter) {
                $sp.Write("`r")
            } elseif ($ch) {
                $sp.Write([string]$ch)
            }
        } else {
            Start-Sleep -Milliseconds 10
        }
    }
}
finally {
    $sp.Close()
    Write-Host "`n=== session closed ===" -ForegroundColor Cyan
}
