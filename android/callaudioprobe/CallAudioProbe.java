// Asks whether a process started over adb, running as the shell user, can reach the
// audio of a regular phone call. Android 13 added AudioManager system APIs for that:
// getCallDownlinkExtractionAudioRecord (what the other party says) and
// getCallUplinkInjectionAudioTrack (what the other party hears). They need
// CALL_AUDIO_INTERCEPTION, which an app cannot hold but the shell user does.
//
//   ./run.sh check                 interceptable or not
//   ./run.sh down <seconds>        record the downlink to /data/local/tmp/down.pcm
//   ./run.sh up <seconds>          play a 440 Hz tone into the uplink
//   ./run.sh stream                bridge a call to the Mac, see below
//
// down and up only work while a call is active. stream listens on the abstract
// socket sidebus-callaudio, which run.sh forwards to tcp:27183 on the Mac. Once a
// client is connected and a call is active, it sends the downlink and injects what it
// receives into the uplink, both as 16 kHz mono 16 bit PCM, until the call ends.

import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Looper;
import android.telephony.TelephonyManager;

import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;

public final class CallAudioProbe {
    private static final int RATE = 16000;
    private static TelephonyManager telephony;
    private static Context context;

    public static void main(String[] args) throws Exception {
        Looper.prepareMainLooper();
        context = shellContext();
        AudioManager audio = context.getSystemService(AudioManager.class);
        telephony = context.getSystemService(TelephonyManager.class);
        String command = args.length > 0 ? args[0] : "check";
        int seconds = args.length > 1 && args[1].matches("\\d+") ? Integer.parseInt(args[1]) : 5;

        boolean interceptable = (boolean) AudioManager.class
                .getMethod("isPstnCallAudioInterceptable").invoke(audio);
        System.out.println("isPstnCallAudioInterceptable: " + interceptable);
        System.out.println("mode: " + audio.getMode());

        AudioFormat format = new AudioFormat.Builder()
                .setSampleRate(RATE)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(command.equals("up")
                        ? AudioFormat.CHANNEL_OUT_MONO : AudioFormat.CHANNEL_IN_MONO)
                .build();

        switch (command) {
            case "down": down(audio, format, seconds); break;
            case "up": up(audio, format, seconds); break;
            case "stream": stream(audio, !(args.length > 1 && args[1].equals("nomute"))); break;
            default: break;
        }
    }

    private static void down(AudioManager audio, AudioFormat format, int seconds) throws Exception {
        AudioRecord record = (AudioRecord) AudioManager.class
                .getMethod("getCallDownlinkExtractionAudioRecord", AudioFormat.class)
                .invoke(audio, format);
        record.startRecording();
        System.out.println("recording state: " + record.getRecordingState());
        byte[] buffer = new byte[RATE * 2 / 10];
        long sum = 0, samples = 0;
        try (FileOutputStream out = new FileOutputStream("/data/local/tmp/down.pcm")) {
            for (int i = 0; i < seconds * 10; i++) {
                int read = record.read(buffer, 0, buffer.length);
                if (read <= 0) { System.out.println("read: " + read); continue; }
                out.write(buffer, 0, read);
                for (int j = 0; j + 1 < read; j += 2) {
                    short s = (short) ((buffer[j] & 0xff) | (buffer[j + 1] << 8));
                    sum += (long) s * s;
                    samples++;
                }
            }
        }
        record.stop();
        record.release();
        System.out.println("samples: " + samples + " rms: " + (samples == 0 ? 0 : (long) Math.sqrt(sum / samples)));
    }

    private static void up(AudioManager audio, AudioFormat format, int seconds) throws Exception {
        // Never outlive the call: a write blocks forever once the call is gone.
        Thread watchdog = new Thread(() -> {
            try { Thread.sleep((seconds + 4) * 1000L); } catch (InterruptedException e) { return; }
            System.out.println("watchdog: giving up");
            System.exit(2);
        });
        watchdog.setDaemon(true);
        watchdog.start();

        AudioDeviceInfo telephony = null;
        for (AudioDeviceInfo device : audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            System.out.println("output: type " + device.getType() + " " + device.getProductName());
            if (device.getType() == AudioDeviceInfo.TYPE_TELEPHONY) telephony = device;
        }

        AudioTrack track = (AudioTrack) AudioManager.class
                .getMethod("getCallUplinkInjectionAudioTrack", AudioFormat.class)
                .invoke(audio, format);
        if (telephony != null) {
            System.out.println("preferred telephony: " + track.setPreferredDevice(telephony));
        } else {
            System.out.println("no telephony output listed");
        }

        // What actually leaves the phone, to check for the tone without a listener.
        AudioRecord uplink = new AudioRecord(MediaRecorder.AudioSource.VOICE_UPLINK, RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, RATE * 2);
        uplink.startRecording();
        Thread recorder = new Thread(() -> record(uplink, seconds, "/data/local/tmp/up.pcm"));
        recorder.start();

        short[] tone = new short[RATE / 10];
        track.play();
        System.out.println("play state: " + track.getPlayState()
                + " routed to: " + (track.getRoutedDevice() == null ? "?" : track.getRoutedDevice().getType()));
        long phase = 0;
        for (int i = 0; i < seconds * 10; i++) {
            for (int j = 0; j < tone.length; j++, phase++) {
                tone[j] = (short) (Math.sin(2 * Math.PI * 440 * phase / RATE) * 12000);
            }
            track.write(tone, 0, tone.length);
        }
        System.out.println("routed to: " + (track.getRoutedDevice() == null ? "?" : track.getRoutedDevice().getType()));
        track.stop();
        track.release();
        recorder.join();
        System.out.println("tone sent");
    }

    private static void stream(AudioManager audio, boolean muteMic) throws Exception {
        // 20 ms frames.
        final int frameBytes = RATE / 50 * 2;
        LocalServerSocket server = new LocalServerSocket("sidebus-callaudio");
        System.out.println("listening on sidebus-callaudio");
        LocalSocket client = server.accept();
        System.out.println("client connected");
        while (audio.getMode() != AudioManager.MODE_IN_CALL) Thread.sleep(100);
        System.out.println("call active");

        AudioFormat in = new AudioFormat.Builder().setSampleRate(RATE)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO).build();
        AudioFormat out = new AudioFormat.Builder().setSampleRate(RATE)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build();
        AudioRecord downlink = (AudioRecord) AudioManager.class
                .getMethod("getCallDownlinkExtractionAudioRecord", AudioFormat.class)
                .invoke(audio, in);
        AudioTrack uplink = injectionTrack(out);
        System.out.println("uplink attribution: " + context.getAttributionSource());
        for (AudioDeviceInfo device : audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            if (device.getType() == AudioDeviceInfo.TYPE_TELEPHONY) uplink.setPreferredDevice(device);
        }
        // The Mac's microphone replaces the phone's, and the voice call volume drops to
        // its minimum. On HyperOS the earpiece cannot go quieter than that without
        // root: the modem feeds it directly, and neither audio modes, stream mute,
        // policy indexes nor routing changes take it off (see the git history).
        boolean wasMuted = audio.isMicrophoneMute();
        int volume = audio.getStreamVolume(AudioManager.STREAM_VOICE_CALL);
        audio.setMicrophoneMute(muteMic);
        System.out.println("phone microphone muted: " + muteMic);
        // Xiaomi's own call relay sets this key next to the mute. With both, the other
        // party hears what is injected and nothing from the phone's microphone.
        audio.setParameters("incall_music_mute=false");
        audio.setStreamVolume(AudioManager.STREAM_VOICE_CALL,
                audio.getStreamMinVolume(AudioManager.STREAM_VOICE_CALL), 0);

        downlink.startRecording();
        uplink.play();
        System.out.println("bridging, uplink routed to "
                + (uplink.getRoutedDevice() == null ? "?" : uplink.getRoutedDevice().getType()));

        OutputStream toMac = client.getOutputStream();
        InputStream fromMac = client.getInputStream();
        Thread receiver = new Thread(() -> {
            byte[] buffer = new byte[frameBytes];
            Level level = new Level("from Mac");
            try {
                int read;
                while ((read = fromMac.read(buffer)) > 0) {
                    uplink.write(buffer, 0, read);
                    level.add(buffer, read);
                }
            } catch (Exception e) {
                System.out.println("from Mac: " + e);
            }
        });
        receiver.setDaemon(true);
        receiver.start();


        byte[] buffer = new byte[frameBytes];
        try {
            long lastMode = -1;
            Level level = new Level("downlink");
            // Not the audio mode: the bridge holds it at call redirect itself, so it
            // would outlive the call.
            while (telephony.getCallState() != TelephonyManager.CALL_STATE_IDLE) {
                if (audio.getMode() != lastMode) {
                    lastMode = audio.getMode();
                    System.out.println("mode " + lastMode);
                }
                int read = downlink.read(buffer, 0, buffer.length);
                if (read > 0) {
                    toMac.write(buffer, 0, read);
                    level.add(buffer, read);
                }
            }
        } catch (Exception e) {
            System.out.println("to Mac: " + e);
        } finally {
            audio.setMicrophoneMute(wasMuted);
            audio.setStreamVolume(AudioManager.STREAM_VOICE_CALL, volume, 0);
            downlink.stop();
            downlink.release();
            uplink.stop();
            uplink.release();
            client.close();
            server.close();
            System.out.println("call ended");
            System.exit(0);
        }
    }

    // What getCallUplinkInjectionAudioTrack builds, but attributed to the shell package
    // through an explicit Context: the helper takes its attribution from the process,
    // which app_process leaves without a package. sparktour's Shizuku SIP gateway hit
    // the same silent uplink and fixed it this way.
    private static AudioTrack injectionTrack(AudioFormat format) throws Exception {
        int pstn = AudioManager.class.getField("CALL_REDIRECT_PSTN").getInt(null);
        AudioAttributes.Builder attributes = new AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH);
        AudioAttributes.Builder.class.getMethod("setSystemUsage", int.class)
                .invoke(attributes, 17); // USAGE_CALL_ASSISTANT, hidden
        AudioTrack.Builder builder = new AudioTrack.Builder()
                .setContext(context)
                .setAudioAttributes(attributes.build())
                .setAudioFormat(format);
        AudioTrack.Builder.class.getMethod("setCallRedirectionMode", int.class).invoke(builder, pstn);
        return builder.build();
    }

    // Logs the RMS of 16 bit PCM every two seconds of audio.
    private static final class Level {
        private final String name;
        private long sum, samples;

        Level(String name) { this.name = name; }

        void add(byte[] buffer, int length) {
            for (int j = 0; j + 1 < length; j += 2) {
                short sample = (short) ((buffer[j] & 0xff) | (buffer[j + 1] << 8));
                sum += (long) sample * sample;
                samples++;
            }
            if (samples >= RATE * 2) {
                System.out.println(name + " rms " + (long) Math.sqrt(sum / samples));
                sum = 0;
                samples = 0;
            }
        }
    }

    private static void record(AudioRecord record, int seconds, String path) {
        byte[] buffer = new byte[RATE * 2 / 10];
        long sum = 0, samples = 0;
        try (FileOutputStream out = new FileOutputStream(path)) {
            for (int i = 0; i < seconds * 10; i++) {
                int read = record.read(buffer, 0, buffer.length);
                if (read <= 0) continue;
                out.write(buffer, 0, read);
                for (int j = 0; j + 1 < read; j += 2) {
                    short s = (short) ((buffer[j] & 0xff) | (buffer[j + 1] << 8));
                    sum += (long) s * s;
                    samples++;
                }
            }
        } catch (Exception e) {
            System.out.println("uplink record: " + e);
        }
        record.stop();
        record.release();
        System.out.println(path + " samples: " + samples + " rms: " + (samples == 0 ? 0 : (long) Math.sqrt(sum / samples)));
    }

    // app_process gives no Context; build the system one, then attribute to the shell
    // package so that app ops check the shell user's permissions.
    private static Context shellContext() throws Exception {
        Class<?> threadClass = Class.forName("android.app.ActivityThread");
        Constructor<?> constructor = threadClass.getDeclaredConstructor();
        constructor.setAccessible(true);
        Object thread = constructor.newInstance();
        Field current = threadClass.getDeclaredField("sCurrentActivityThread");
        current.setAccessible(true);
        current.set(null, thread);
        Context system = (Context) threadClass.getDeclaredMethod("getSystemContext").invoke(thread);
        return new ShellContext(system.createPackageContext("com.android.shell", 0));
    }

    // A package context still hands out the system's attribution ("android"), which
    // AudioFlinger refuses for uid 2000. This one presents the shell package throughout.
    private static final class ShellContext extends ContextWrapper {
        ShellContext(Context base) { super(base); }
        @Override public String getPackageName() { return "com.android.shell"; }
        @Override public String getOpPackageName() { return "com.android.shell"; }
        @Override public AttributionSource getAttributionSource() {
            return new AttributionSource.Builder(2000).setPackageName("com.android.shell").build();
        }
        @Override public Context getApplicationContext() { return this; }
    }
}
