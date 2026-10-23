# Probe: can this Windows PC talk to the MW75 through its Bluetooth serial (SPP) port?
#
# Run it with the headset paired and worn:
#   right-click this file > "Run with PowerShell"
# It finds the Bluetooth serial ports Windows made for the MW75, sends the same
# enable_raw_mode command the app sends, listens for 4 seconds, then sends
# disable_raw_mode. Nothing is installed or changed.
#
# Read the result:
#   a short reply such as "FF 03 00 01 09 9A 03 41 F1"  -> commands work over the COM port
#   hundreds of bytes or more                           -> EEG data also arrives over it
#   0 bytes or an error                                 -> try the other port / report the text

$addr = '500B91A93984'   # the lab MW75's Bluetooth address, 50:0B:91:A9:39:84
$on   = [byte[]](0xFF, 0x04, 0x00, 0x01, 0x09, 0x9A, 0x03, 0x41, 0x01)
$off  = [byte[]](0xFF, 0x04, 0x00, 0x01, 0x09, 0x9A, 0x03, 0x41, 0x00)

$all = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -like '*Standard Serial over Bluetooth*' })
Write-Host "Bluetooth serial ports found: $($all.Count)"
foreach ($e in $all) { Write-Host ("  {0}`n    {1}" -f $e.Name, $e.DeviceID) }

$mine = @($all | Where-Object { $_.DeviceID -like "*$addr*" })
if ($mine.Count -eq 0) {
    Write-Host "`nNo port is tied to $addr, so trying every Bluetooth serial port."
    $mine = $all
}

foreach ($e in $mine) {
    if ($e.Name -notmatch '\((COM\d+)\)') { continue }
    $com = $Matches[1]
    Write-Host "`n=== $com ==="
    $p = $null
    try {
        $p = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
        $p.ReadTimeout = 3000
        $p.WriteTimeout = 3000
        Write-Host 'Opening (an outgoing port connects to the headset now, which can take a few seconds)...'
        $p.Open()
        Write-Host 'Opened. Sending enable_raw_mode...'
        $p.Write($on, 0, $on.Length)
        Start-Sleep -Seconds 4
        $n = $p.BytesToRead
        $buf = New-Object byte[] $n
        if ($n -gt 0) { [void]$p.Read($buf, 0, $n) }
        Write-Host "Received $n bytes in 4 seconds."
        if ($n -gt 0) {
            Write-Host 'First bytes:'
            Write-Host (($buf | Select-Object -First 48 | ForEach-Object { $_.ToString('X2') }) -join ' ')
        }
        $p.Write($off, 0, $off.Length)
        Start-Sleep -Milliseconds 500
    }
    catch {
        Write-Host "Error on ${com}: $($_.Exception.Message)"
    }
    finally {
        if ($p -ne $null -and $p.IsOpen) { $p.Close() }
    }
}

Write-Host "`nDone. Take a photo of this window, then press Enter to close."
[void](Read-Host)
