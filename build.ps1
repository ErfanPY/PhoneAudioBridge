# Builds both halves of the bridge:
#   phone-speaker\android\pcaudio.jar   the player that runs on the phone (via app_process)
#   phone-speaker\bin\pc-audio-sender   the PC side that captures Windows audio
# Needs: a JDK (javac), the Android SDK (platforms + build-tools), and the .NET SDK.
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$android = "$PSScriptRoot\phone-speaker\android"
$pc = "$PSScriptRoot\phone-speaker\pc"

$androidJar = Get-ChildItem "$sdk\platforms\android-*\android.jar" |
    Sort-Object { [version]($_.Directory.Name -replace '^android-|-.*$', '' -replace '^(\d+)$', '$1.0') } |
    Select-Object -Last 1 -ExpandProperty FullName
$d8 = Get-ChildItem "$sdk\build-tools\*\d8.bat" | Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName
if (-not $androidJar -or -not $d8) { throw "Android SDK platforms/build-tools not found under $sdk" }

New-Item -ItemType Directory -Force "$android\build" | Out-Null
javac --release 8 -Xlint:-options -cp $androidJar -d "$android\build" "$android\PcAudioPlayer.java"
if ($LASTEXITCODE) { throw "javac failed" }
& $d8 --min-api 26 --lib $androidJar --output "$android\pcaudio.jar" "$android\build\PcAudioPlayer.class"
if ($LASTEXITCODE) { throw "d8 failed" }

dotnet build $pc -c Release -o "$PSScriptRoot\phone-speaker\bin"
if ($LASTEXITCODE) { throw "dotnet build failed" }
Write-Host "Built. Run .\phone-bridge.ps1"
