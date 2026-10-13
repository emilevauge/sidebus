// Phone half of Sidebus calls: carries a phone call's audio to and from the Mac.
//
// The Mac pushes this file as a dex and starts it over adb, as the shell user, which
// holds CALL_AUDIO_INTERCEPTION: an installed app cannot reach call audio. Started
// detached from the adb session, it outlives the USB cable and runs until the phone
// restarts.
//
// It listens on 127.0.0.1:27186. SELinux keeps apps from connecting to a shell
// process's Unix sockets, but not to a local TCP port, which any app may reach. So both
// ends prove they know a secret, without sending it: the Mac draws it when it starts the
// helper, passes it as the first argument, keeps a copy in /data/local/tmp (out of
// apps' reach) and hands it to the Sidebus app over adb. A connection opens with
//
//   helper -> app   16 random bytes, n1
//   app -> helper   HMAC(secret, "app" n1), then 16 random bytes, n2
//   helper -> app   HMAC(secret, "helper" n2)
//
// HMAC is SHA-256. Then one command byte:
//
//   P   is the bridge running? It answers K and closes.
//   C   carry a call: once the call is up, the downlink (the other party) goes out on
//       the socket, and what comes in (the Mac's microphone) goes into the uplink, both
//       as 16 kHz mono 16 bit little endian PCM, until the call ends or the socket
//       closes.
//
// The app relays between this socket and the Mac, over Sidebus's call channel.
//
// android/callaudioprobe holds the experiments behind each choice made here.

import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.os.Looper;
import android.telephony.TelephonyManager;

import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.security.MessageDigest;
import java.security.SecureRandom;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

public final class CallBridge {
    private static final int RATE = 16000;
    private static final int FRAME_BYTES = RATE / 50 * 2;
    // Audio from the Mac allowed to wait in the socket, 200 ms, and what is kept when it
    // goes beyond, 60 ms. The gap between the two keeps drops rare: each one clicks.
    private static final int MAX_BACKLOG_BYTES = RATE / 5 * 2;
    private static final int KEPT_BACKLOG_BYTES = RATE * 6 / 100 * 2;
    // How long a connection may wait for its call to come up.
    private static final long CALL_WAIT_MS = 15_000;
    private static final int PORT = 27186;
    private static byte[] secret;

    private static Context context;
    private static AudioManager audio;
    private static TelephonyManager telephony;

    public static void main(String[] args) throws Exception {
        Looper.prepareMainLooper();
        context = shellContext();
        // Built on the shell context itself: the system service hands back one tied to
        // the package context, whose missing application context breaks some calls.
        Constructor<AudioManager> constructor = AudioManager.class.getDeclaredConstructor(Context.class);
        constructor.setAccessible(true);
        audio = constructor.newInstance(context);
        telephony = context.getSystemService(TelephonyManager.class);

        boolean interceptable = (boolean) AudioManager.class
                .getMethod("isPstnCallAudioInterceptable").invoke(audio);
        if (!interceptable) {
            System.out.println("error: call audio cannot be intercepted on this phone");
            System.exit(1);
        }

        secret = hex(args[0]);
        ServerSocket server = new ServerSocket(PORT, 16, InetAddress.getLoopbackAddress());
        System.out.println("ready");
        while (true) {
            Socket client = server.accept();
            // One thread per connection: a check must get its answer while a call is
            // carried, or the app takes the helper for gone.
            Thread thread = new Thread(() -> serve(client));
            thread.setDaemon(true);
            thread.start();
        }
    }

    /** The call being carried, closed when another takes its place. */
    private static Socket current;

    private static void serve(Socket client) {
        try (Socket socket = client) {
            socket.setTcpNoDelay(true);
            socket.setSoTimeout(5_000);
            if (!authenticate(socket)) {
                System.out.println("refused a client without the secret");
                return;
            }
            socket.setSoTimeout(0);
            int command = socket.getInputStream().read();
            if (command == 'P') {
                socket.getOutputStream().write('K');
                return;
            }
            if (command != 'C') return;
            synchronized (CallBridge.class) {
                if (current != null) {
                    try { current.close(); } catch (IOException ignored) { }
                }
                current = socket;
            }
            if (awaitCall(socket)) bridge(socket);
        } catch (Exception e) {
            System.out.println("bridge: " + e);
        } finally {
            synchronized (CallBridge.class) {
                if (current == client) current = null;
            }
        }
    }

    private static boolean authenticate(Socket client) throws Exception {
        DataInputStream in = new DataInputStream(client.getInputStream());
        OutputStream out = client.getOutputStream();
        byte[] ours = new byte[16];
        new SecureRandom().nextBytes(ours);
        out.write(ours);
        byte[] proof = new byte[32];
        byte[] theirs = new byte[16];
        in.readFully(proof);
        in.readFully(theirs);
        if (!MessageDigest.isEqual(proof, hmac("app", ours))) return false;
        out.write(hmac("helper", theirs));
        return true;
    }

    private static byte[] hmac(String label, byte[] nonce) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(secret, "HmacSHA256"));
        mac.update(label.getBytes("UTF-8"));
        return mac.doFinal(nonce);
    }

    private static byte[] hex(String text) {
        byte[] bytes = new byte[text.length() / 2];
        for (int i = 0; i < bytes.length; i++) {
            bytes[i] = (byte) Integer.parseInt(text.substring(2 * i, 2 * i + 2), 16);
        }
        return bytes;
    }

    private static boolean awaitCall(Socket socket) throws Exception {
        long deadline = System.currentTimeMillis() + CALL_WAIT_MS;
        InputStream in = socket.getInputStream();
        byte[] drain = new byte[4096];
        while (telephony.getCallState() != TelephonyManager.CALL_STATE_OFFHOOK
                || audio.getMode() != AudioManager.MODE_IN_CALL) {
            if (System.currentTimeMillis() > deadline || socket.isClosed()) {
                System.out.println("no call came up");
                return false;
            }
            // The Mac's microphone may already flow: read it away rather than let it
            // fill the socket and stall the app.
            while (in.available() > 0) in.read(drain, 0, Math.min(drain.length, in.available()));
            Thread.sleep(50);
        }
        return true;
    }

    private static void bridge(Socket client) throws Exception {
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
        for (AudioDeviceInfo device : audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            if (device.getType() == AudioDeviceInfo.TYPE_TELEPHONY) uplink.setPreferredDevice(device);
        }

        // The Mac's microphone replaces the phone's, and the earpiece drops to its
        // minimum: on a Xiaomi with HyperOS it cannot be silenced without root.
        boolean wasMuted = audio.isMicrophoneMute();
        int volume = audio.getStreamVolume(AudioManager.STREAM_VOICE_CALL);
        audio.setMicrophoneMute(true);
        // Xiaomi's own call relay sets this key next to the mute. With both, the other
        // party hears what is injected and nothing from the phone's microphone.
        audio.setParameters("incall_music_mute=false");
        audio.setStreamVolume(AudioManager.STREAM_VOICE_CALL,
                audio.getStreamMinVolume(AudioManager.STREAM_VOICE_CALL), 0);

        downlink.startRecording();
        uplink.play();
        System.out.println("bridging");

        InputStream fromMac = client.getInputStream();
        OutputStream toMac = client.getOutputStream();
        Thread receiver = new Thread(() -> {
            try {
                receive(fromMac, uplink);
            } catch (Exception e) {
                // The connection is gone; the sending side notices on its own.
            }
        });
        receiver.setDaemon(true);
        receiver.start();

        byte[] buffer = new byte[FRAME_BYTES];
        try {
            while (receiver.isAlive() && !client.isClosed()
                    && telephony.getCallState() != TelephonyManager.CALL_STATE_IDLE) {
                int read = downlink.read(buffer, 0, buffer.length);
                if (read > 0) toMac.write(buffer, 0, read);
            }
        } catch (IOException e) {
            // The Mac closed the connection: the call stays up, on the phone.
        } finally {
            audio.setMicrophoneMute(wasMuted);
            audio.setStreamVolume(AudioManager.STREAM_VOICE_CALL, volume, 0);
            downlink.stop();
            downlink.release();
            uplink.stop();
            uplink.release();
            System.out.println("bridge ended");
        }
    }

    private static void receive(InputStream fromMac, AudioTrack uplink) throws IOException {
        byte[] buffer = new byte[FRAME_BYTES];
        // The Mac may have started sending before the call came up, and a blocked write
        // lets more pile up: play only the latest audio, or the other party hears it late.
        skipBacklog(fromMac, 0);
        int held = 0, read;
        while (true) {
            if (held == 0 && fromMac.available() > MAX_BACKLOG_BYTES) {
                skipBacklog(fromMac, KEPT_BACKLOG_BYTES);
            }
            if ((read = fromMac.read(buffer, held, buffer.length - held)) <= 0) return;
            // A read may end in the middle of a sample; AudioTrack refuses that write
            // whole, so keep the odd byte for the next one.
            int length = held + read;
            int whole = length & ~1;
            uplink.write(buffer, 0, whole);
            held = length - whole;
            if (held > 0) buffer[0] = buffer[whole];
        }
    }

    // Drops what waits beyond keep bytes, in whole samples.
    private static void skipBacklog(InputStream in, int keep) throws IOException {
        int excess = (in.available() - keep) & ~1;
        long skipped = 0;
        while (skipped < excess) skipped += in.skip(excess - skipped);
    }

    // What getCallUplinkInjectionAudioTrack builds, but attributed to the shell package
    // through an explicit Context: the helper takes its attribution from the process,
    // which app_process leaves as "android", and the other party then hears nothing.
    // The fix comes from github.com/sparkcyf/android-voice-sip-agent.
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

    // app_process gives no Context: build the system one, then present the shell
    // package, so that permission and app op checks see the shell user.
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
