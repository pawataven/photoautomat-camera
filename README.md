# photoautomat-camera

Android app that turns a phone's back camera into the Photoautomat booth camera over Wi-Fi.

- Finds the booth by its UDP beacon (port 8766), or uses the address typed under "ที่อยู่ตู้".
- Streams ~15 fps 640 px JPEG frames while the booth is on the capture screen.
- On the booth's capture command, takes a full-resolution photo with the chosen flash mode
  (always / auto / off, remembered) and sends it back.

The protocol is documented at the top of `lib/booth_link.dart` and must stay in step with
`photoautomat/lib/services/phone_camera_service_io.dart`.

## Build

```
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`. It is signed with the debug key, which is fine
for installing on booth phones directly (no Play Store).
