# Two-way audio bridge to the phone over adb, via USB or Wi-Fi. Stop with Ctrl+C.
#   PC sound -> phone : loopback of the Windows default output -> PcAudioPlayer on the phone
#   phone mic -> PC   : scrcpy (mic only) -> "CABLE Input" -> apps use "CABLE Output" as the mic
# Start it with or without the phone: it waits, connects when the phone appears, and goes
# back to waiting if the phone drops.
#   USB plugged in : used first. The phone's Wi-Fi address is saved to phone.ip and adb over
#                    Wi-Fi (port 5555) is switched on, ready for when there is no cable.
#   No cable       : connects to the address in phone.ip (PC and phone on the same network).
#                    After a phone reboot, plug in USB once to switch Wi-Fi adb back on.
# One-time setup: Settings > System > Sound > Volume mixer > scrcpy > Output = CABLE Input.
param(
    [switch]$NoMic,      # only send PC sound to the phone
    [switch]$NoSpeaker   # only bring the phone mic to the PC
)

$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$scrcpy = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Genymobile.scrcpy_Microsoft.Winget.Source_8wekyb3d8bbwe\scrcpy-win64-v5.0.1\scrcpy.exe"
$sender = "$PSScriptRoot\phone-speaker\bin\pc-audio-sender.exe"
$playerJar = "$PSScriptRoot\phone-speaker\android\pcaudio.jar"
$ipFile = "$PSScriptRoot\phone.ip"
$env:ADB = $adb

function Test-Port($ip, $port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { return $c.ConnectAsync($ip, $port).Wait(1500) } catch { return $false } finally { $c.Dispose() }
}

# Serial of a phone attached over USB, or $null. Wi-Fi entries look like "ip:port".
function Get-UsbSerial {
    & $adb devices | Select-String '^(\S+)\s+device$' |
        ForEach-Object { $_.Matches.Groups[1].Value } | Where-Object { $_ -notmatch ':' } | Select-Object -First 1
}

# While on USB: remember the phone's Wi-Fi address and make sure adb listens on port 5555.
function Enable-WifiAdb($serial) {
    $out = & $adb -s $serial shell "ip -f inet addr show wlan0" 2>$null | Out-String
    if ($out -notmatch 'inet (\d+\.\d+\.\d+\.\d+)') { return }
    $ip = $Matches[1]
    if ((Test-Path $ipFile) -and ((Get-Content $ipFile -Raw).Trim() -eq $ip) -and (Test-Port $ip 5555)) { return }
    Set-Content $ipFile $ip
    if (-not (Test-Port $ip 5555)) {
        Write-Host "Enabling adb over Wi-Fi ($ip)..."
        & $adb -s $serial tcpip 5555 | Out-Null
        Start-Sleep -Seconds 4   # adb restarts on the phone; the USB link drops briefly
    }
}

# Returns the adb serial to use, or $null if the phone cannot be reached yet.
function Find-Phone {
    $usb = Get-UsbSerial
    if ($usb) { Enable-WifiAdb $usb; return (Get-UsbSerial) }
    if (Test-Path $ipFile) {
        $ip = (Get-Content $ipFile -Raw).Trim()
        if (Test-Port $ip 5555) {
            & $adb connect "${ip}:5555" 2>$null | Out-Null
            if ((& $adb -s "${ip}:5555" get-state 2>$null | Out-String).Trim() -eq "device") { return "${ip}:5555" }
        }
    }
    return $null
}

function Wait-ForPhone {
    $shown = $false
    while ($true) {
        $serial = Find-Phone
        if ($serial) { return $serial }
        if (-not $shown) {
            Write-Host "Waiting for the phone (USB, or the saved Wi-Fi address if there is one)..."
            $shown = $true
        }
        Start-Sleep -Seconds 2
    }
}

function Start-Session($serial) {
    $env:ANDROID_SERIAL = $serial   # adb and scrcpy both target this device
    $wifi = $serial -match ':'
    Write-Host "Using phone $serial ($(if ($wifi) { 'Wi-Fi' } else { 'USB' }))"
    $buffer = if ($wifi) { 120 } else { 40 }   # more headroom for Wi-Fi jitter
    $procs = @()
    try {
        if (-not $NoMic) {
            $procs += Start-Process $scrcpy -PassThru -WindowStyle Hidden -ArgumentList `
                "--no-video", "--no-control", "--no-window", "--audio-source=mic", "--audio-buffer=$buffer"
            Write-Host "Phone mic -> CABLE Output"
        }
        if (-not $NoSpeaker) {
            & $adb push $playerJar /data/local/tmp/pcaudio.jar | Out-Null
            & $adb shell "pkill -f PcAudioPlayer" 2>$null
            & $adb forward tcp:27200 localabstract:pcaudio | Out-Null
            $procs += Start-Process $adb -PassThru -WindowStyle Hidden -ArgumentList `
                "shell", "CLASSPATH=/data/local/tmp/pcaudio.jar app_process / PcAudioPlayer"
            Start-Sleep -Milliseconds 1500  # let the player start listening
            $procs += Start-Process $sender -PassThru -NoNewWindow
        }
        Write-Host "Connected. Ctrl+C to stop."
        # Stay until the phone drops or a bridge process dies.
        while ((& $adb -s $serial get-state 2>$null | Out-String).Trim() -eq "device" -and -not ($procs | Where-Object HasExited)) {
            Start-Sleep -Seconds 2
        }
        Write-Host "Phone disconnected or bridge stopped."
    } finally {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        & $adb shell "pkill -f PcAudioPlayer" 2>$null
        & $adb forward --remove tcp:27200 2>$null
        Remove-Item Env:ANDROID_SERIAL -ErrorAction SilentlyContinue
    }
}

& $adb start-server 2>$null | Out-Null
try {
    while ($true) {
        $serial = Wait-ForPhone
        Start-Session $serial
        Start-Sleep -Seconds 2
    }
} finally {
    Write-Host "Bridge stopped."
}
