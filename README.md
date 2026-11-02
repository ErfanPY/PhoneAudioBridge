# PhoneAudioBridge

Use an Android phone as a two-way audio bridge for a Windows PC, over USB or Wi-Fi, through `adb`.
Plug a headset into the phone and it becomes the PC's headphones and microphone.

- **PC sound -> phone**: Windows output is captured (WASAPI loopback) and played on the phone.
- **Phone mic -> PC**: the phone mic is streamed by [scrcpy](https://github.com/Genymobile/scrcpy) into a
  virtual cable, which apps see as a microphone.

Nothing is installed on the phone. The phone-side player is a small Java class started with `app_process`,
the same way scrcpy runs its server.

## Requirements

- Windows 10/11, Android 11+ with USB debugging enabled
- `adb` ([platform-tools](https://developer.android.com/tools/releases/platform-tools)) and
  `scrcpy` (`winget install Genymobile.scrcpy`)
- [VB-Cable](https://vb-audio.com/Cable/) virtual audio device
- To build: a JDK, the Android SDK (platform + build-tools) and the .NET SDK

## Setup

1. `.\build.ps1`
2. Settings > System > Sound > Volume mixer > **scrcpy** > Output device = **CABLE Input**
   (once, after scrcpy has played sound the first time).
3. In your apps, choose **CABLE Output** as the microphone. To make it the Windows default:
   `phone-speaker\bin\pc-audio-sender.exe --set-default "CABLE Output"`

The paths to `adb` and `scrcpy` at the top of `phone-bridge.ps1` assume the Android SDK and winget
default locations; edit them if yours differ.

## Use

```powershell
.\phone-bridge.ps1              # both directions
.\phone-bridge.ps1 -NoMic       # only PC sound -> phone
.\phone-bridge.ps1 -NoSpeaker   # only phone mic -> PC
```

Start it with or without the phone. It waits, connects when the phone appears, and reconnects if the
phone drops.

- **USB plugged in**: used first. The phone's Wi-Fi address is saved to `phone.ip` and adb over Wi-Fi
  (port 5555) is switched on.
- **No cable**: connects to the address in `phone.ip`, if the PC and phone are on the same network.
  Wi-Fi sessions use a larger audio buffer. After a phone reboot, plug in USB once to turn adb over
  Wi-Fi back on.

Sound plays on the phone only while the bridge runs, and follows the Windows default output device.
`pc-audio-sender.exe --list` shows output devices, `--device <name>` picks one, and
`--set-default <name>` changes the Windows default (playback or recording).

Expect roughly 100-150 ms of delay over USB, more over Wi-Fi.

## Layout

| Path | What |
| --- | --- |
| `phone-bridge.ps1` | Launcher: finds the phone, starts both directions, reconnects |
| `build.ps1` | Builds the phone player and the PC sender |
| `phone-speaker/android/PcAudioPlayer.java` | Phone-side player (drops audio when it falls behind) |
| `phone-speaker/pc/` | PC-side sender (.NET + NAudio) |
