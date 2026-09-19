# The camera extension, and how to test it without a paid account

Sidebus receives the phone camera and draws it in a window. That window can be shared in a
meeting application, which puts the picture through, but it is not a camera: Zoom, Meet and
FaceTime will not list it.

Making it a real camera means a Core Media I/O extension, a separate sandboxed process the
system launches whenever an application opens the device. The code is in
`mac/Sources/SidebusCameraExtension`. Installing it is the problem.

## Why it needs a paid account

Requesting the install needs `com.apple.developer.system-extension.install`. That
entitlement is restricted: it is only valid inside a provisioning profile issued by Apple,
and the Apple Developer Program is the only way to get one.

Two things were measured on this machine, not assumed:

- A self signed binary carrying the entitlement is killed the moment it launches,
  `Code=-413 "No matching profile found"`.
- Xcode with the personal team answers: *Personal development teams, including 'Emile
  Vauge', do not support the System Extension capability.*

So there is no path through the free tier. What follows is the other way round: stop the
machine from checking.

## What has to be turned off

Two separate protections, on an Apple Silicon Mac:

| Protection | What it does here | How it is turned off |
| --- | --- | --- |
| System Integrity Protection | keeps `nvram boot-args` read only, among much else | `csrutil disable`, from recoveryOS |
| AMFI | validates code signatures and entitlements at launch | `amfi_get_out_of_my_way=0x1` in `boot-args` |

AMFI is the one that matters: it is what kills a binary carrying an entitlement it was not
granted. SIP has to go first only because setting `boot-args` needs it out of the way.

Be clear about the cost. With AMFI disabled, any binary on the machine can claim any
entitlement, and macOS stops telling you when something has been tampered with. This is a
development machine setting, not something to leave on.

## Steps

All of this is yours to run: it needs recoveryOS and two restarts.

1. Shut down. Hold the power button until **Loading startup options** appears, choose
   **Options**, **Continue**, pick the disk and authenticate.
2. Menu bar, **Utilities** then **Terminal**:

   ```
   csrutil disable
   ```

   Confirm, authenticate. On Apple Silicon this moves the security policy to Permissive,
   which is what allows `boot-args` later.
3. Restart into macOS, then check and set:

   ```
   csrutil status                 # expected: disabled
   sudo nvram boot-args="amfi_get_out_of_my_way=0x1"
   ```

   If `nvram` answers *Operation not permitted*, the policy is still Reduced: go back to
   recoveryOS and run `bputil -d` to see the current state.
4. Restart again. Then:

   ```
   nvram boot-args                # expected: amfi_get_out_of_my_way=0x1
   systemextensionsctl developer on
   ```

   Developer mode lets an application install an extension from outside `/Applications` and
   replace it without a version bump, which is what makes an edit, build, test loop bearable.

## Building and installing

The ordinary build does not carry the extension, and must not: the restricted entitlement
alone is enough to get the application killed on a machine with its protections on.

```
SIDEBUS_CAMERA_EXTENSION=1 mac/Scripts/bundle.sh
```

This embeds the extension in `Contents/Library/SystemExtensions`, signs it inside out with
the Apple Development identity, and signs the application with
`Sidebus-CameraExtension.entitlements`. The mach service name is built from the Team ID read
off the signing certificate, because the system requires that prefix.

Then launch Sidebus, open **Settings**, the **Camera** tab, and press **Install**. macOS asks
for approval in **System Settings > General > Login Items & Extensions**. Check the result:

```
systemextensionsctl list
```

Photo Booth is the quickest place to see whether the device shows up. This first version
draws a moving bar, not the phone: the point is to find out whether the install goes through
at all before wiring anything real to it.

## Turning it all back on

```
sudo nvram -d boot-args
systemextensionsctl developer off
```

then `csrutil enable` from recoveryOS, and restart.

## What is likely to break anyway

The entitlement is the known wall, and AMFI removes it. Two others may be waiting behind it,
and neither has been tested yet:

- `sysextd` does its own validation of the extension's signature and of the Team ID prefix
  on `CMIOExtensionMachServiceName`. The prefix is satisfied here, `PYTYLAY9L2` comes from a
  real Apple Development certificate, but the daemon may still want a profile.
- A CMIO extension has to be sandboxed, and the sandbox profile is derived from the
  entitlements. An unregistered app group would be refused; the extension therefore asks for
  nothing but `com.apple.security.app-sandbox`.

If it does work, the next step is carrying real frames from the application to the
extension, over an XPC mach service, with `IOSurface` backed buffers so nothing is copied.
