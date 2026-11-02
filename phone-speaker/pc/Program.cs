// Captures what a Windows output device is playing (WASAPI loopback) and streams it to the
// phone's PcAudioPlayer through `adb forward tcp:27200 localabstract:pcaudio`.
// Usage: pc-audio-sender [--port 27200] [--device <name part>] [--list] [--set-default <name part>]
using System.Net.Sockets;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;

int port = 27200;
string? deviceName = null;
for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--port": port = int.Parse(args[++i]); break;
        case "--device": deviceName = args[++i]; break;
        case "--list":
            foreach (var d in new MMDeviceEnumerator().EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
                Console.WriteLine(d.FriendlyName);
            return;
        case "--set-default":
            var targetName = args[++i];
            // Matches playback and recording devices, e.g. "CABLE Output" to make it the default mic.
            var target = new MMDeviceEnumerator().EnumerateAudioEndPoints(DataFlow.All, DeviceState.Active)
                .First(d => d.FriendlyName.Contains(targetName, StringComparison.OrdinalIgnoreCase));
            var policy = (IPolicyConfig)new PolicyConfigClient();
            foreach (var role in new[] { Role.Console, Role.Multimedia, Role.Communications })
                Marshal.ThrowExceptionForHR(policy.SetDefaultEndpoint(target.ID, role));
            Console.WriteLine($"Default {(target.DataFlow == DataFlow.Capture ? "mic" : "output")}: {target.FriendlyName}");
            return;
    }
}

var enumerator = new MMDeviceEnumerator();
var device = deviceName == null
    ? enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)
    : enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)
        .First(d => d.FriendlyName.Contains(deviceName, StringComparison.OrdinalIgnoreCase));

using var capture = new WasapiLoopbackCapture(device);
var fmt = capture.WaveFormat;
int inChannels = fmt.Channels;
int outChannels = Math.Min(inChannels, 2);
// The shared-mode mix format is 32-bit float in practice, often wrapped as WAVE_FORMAT_EXTENSIBLE.
bool isFloat = fmt.Encoding == WaveFormatEncoding.IeeeFloat
    || (fmt.Encoding == WaveFormatEncoding.Extensible && fmt.BitsPerSample == 32);
if (!isFloat && fmt.BitsPerSample != 16)
    throw new NotSupportedException($"Unsupported capture format: {fmt}");

using var client = new TcpClient { NoDelay = true };
client.Connect("127.0.0.1", port);
var stream = client.GetStream();
stream.Write([(byte)(fmt.SampleRate >> 24), (byte)(fmt.SampleRate >> 16), (byte)(fmt.SampleRate >> 8), (byte)fmt.SampleRate, (byte)outChannels]);
Console.WriteLine($"Streaming '{device.FriendlyName}' ({fmt.SampleRate} Hz, {inChannels} ch) to phone. Ctrl+C to stop.");

var done = new ManualResetEventSlim();
byte[] outBuf = [];
capture.DataAvailable += (_, e) =>
{
    int inFrameBytes = fmt.BlockAlign;
    int frames = e.BytesRecorded / inFrameBytes;
    int outBytes = frames * outChannels * 2;
    if (outBuf.Length < outBytes) outBuf = new byte[outBytes];
    int o = 0;
    for (int f = 0; f < frames; f++)
    {
        for (int c = 0; c < outChannels; c++)
        {
            short s;
            if (isFloat)
            {
                float v = BitConverter.ToSingle(e.Buffer, f * inFrameBytes + c * 4);
                s = (short)(Math.Clamp(v, -1f, 1f) * short.MaxValue);
            }
            else
            {
                s = BitConverter.ToInt16(e.Buffer, f * inFrameBytes + c * 2);
            }
            outBuf[o++] = (byte)s;
            outBuf[o++] = (byte)(s >> 8);
        }
    }
    try { stream.Write(outBuf, 0, o); }
    catch (IOException) { Console.WriteLine("Phone disconnected."); done.Set(); }
};
capture.RecordingStopped += (_, _) => done.Set();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; done.Set(); };

// Loopback delivers nothing while the device is silent, so keep the phone fed with silence
// to stop its buffer from underrunning and clicking when sound resumes.
using var silence = new SilencePlayer(device, fmt.SampleRate, inChannels);
capture.StartRecording();
done.Wait();
capture.StopRecording();

sealed class SilencePlayer : IDisposable
{
    private readonly WasapiOut _out;
    public SilencePlayer(MMDevice device, int sampleRate, int channels)
    {
        _out = new WasapiOut(device, AudioClientShareMode.Shared, true, 50);
        _out.Init(new NAudio.Wave.SampleProviders.SignalGenerator(sampleRate, channels) { Gain = 0 });
        _out.Play();
    }
    public void Dispose() => _out.Dispose();
}

// Undocumented but long-stable Windows interface that the Sound control panel uses to set defaults.
[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
class PolicyConfigClient { }

[ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPolicyConfig
{
    [PreserveSig] int GetMixFormat(IntPtr a, IntPtr b);
    [PreserveSig] int GetDeviceFormat(IntPtr a, int b, IntPtr c);
    [PreserveSig] int ResetDeviceFormat(IntPtr a);
    [PreserveSig] int SetDeviceFormat(IntPtr a, IntPtr b, IntPtr c);
    [PreserveSig] int GetProcessingPeriod(IntPtr a, int b, IntPtr c, IntPtr d);
    [PreserveSig] int SetProcessingPeriod(IntPtr a, IntPtr b);
    [PreserveSig] int GetShareMode(IntPtr a, IntPtr b);
    [PreserveSig] int SetShareMode(IntPtr a, IntPtr b);
    [PreserveSig] int GetPropertyValue(IntPtr a, IntPtr b, IntPtr c);
    [PreserveSig] int SetPropertyValue(IntPtr a, IntPtr b, IntPtr c);
    [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, Role role);
    [PreserveSig] int SetEndpointVisibility(IntPtr a, int b);
}
