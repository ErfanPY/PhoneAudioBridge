// Runs on the phone via `app_process` (like scrcpy-server), so no APK install is needed.
// Listens on the abstract socket "pcaudio" (reached from the PC with `adb forward`) and plays
// the incoming stream: header = int32 BE sample rate, int8 channels; then s16le PCM.
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Looper;

import java.io.DataInputStream;
import java.io.InputStream;

public class PcAudioPlayer {
    // Drop queued audio when more than this is waiting, so latency can't creep up from clock drift.
    private static final int MAX_QUEUED_MS = 120;

    public static void main(String[] args) throws Exception {
        Looper.prepare();
        LocalServerSocket server = new LocalServerSocket("pcaudio");
        System.out.println("pcaudio: listening");
        while (true) {
            try (LocalSocket client = server.accept()) {
                play(client.getInputStream());
            } catch (Exception e) {
                System.out.println("pcaudio: client ended: " + e);
            }
        }
    }

    private static void play(InputStream raw) throws Exception {
        DataInputStream in = new DataInputStream(raw);
        int rate = in.readInt();
        int channels = in.readByte();
        int channelMask = channels == 1 ? AudioFormat.CHANNEL_OUT_MONO : AudioFormat.CHANNEL_OUT_STEREO;
        int frameBytes = 2 * channels;
        int minBuf = AudioTrack.getMinBufferSize(rate, channelMask, AudioFormat.ENCODING_PCM_16BIT);

        AudioTrack track = new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build())
                .setAudioFormat(new AudioFormat.Builder()
                        .setSampleRate(rate)
                        .setChannelMask(channelMask)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .build())
                .setBufferSizeInBytes(minBuf * 2)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                .build();
        track.play();
        System.out.println("pcaudio: playing " + rate + " Hz, " + channels + " ch");

        int maxQueued = rate * frameBytes * MAX_QUEUED_MS / 1000;
        byte[] buf = new byte[(rate / 200) * frameBytes]; // 5 ms chunks, whole frames
        try {
            while (true) {
                in.readFully(buf); // EOFException when the PC disconnects
                if (in.available() < maxQueued) {
                    track.write(buf, 0, buf.length);
                } // else: too far behind, drop this chunk to catch up
            }
        } finally {
            track.stop();
            track.release();
        }
    }
}
