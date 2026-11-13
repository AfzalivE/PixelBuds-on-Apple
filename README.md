# Buds Battery (iOS and macOS)

A SwiftUI app that shows the battery level of the left bud, the right bud, and the case of Pixel Buds (and other Google Fast Pair earbuds). On macOS, the app also shows the levels in the menu bar.

Tested on macOS with Pixel Buds Pro 2. The iOS app builds, but it is not tested on real buds.

## How it gets the data

The app uses four sources. When more than one source has data, it uses this order: Message Stream, BLE Battery Service, BLE advertisement.

1. **Fast Pair Message Stream (macOS only).** This is an RFCOMM channel on Bluetooth Classic, UUID `df21fe2c-2515-4fdb-8886-f12c4d67927c`. When the channel opens, and each time a level changes, the buds send a "battery updated" message: group `0x03`, code `0x03`, then 3 battery bytes (left, right, case). Each byte is `0bSVVVVVVV`. S = 1 when the part charges. V = level from 0 to 100, or `0x7F` when the level is unknown. Pixel Buds Pro 2 always send `0x7F` (unknown) for the case.
2. **Maestro (macOS only).** Maestro is a Google protocol for Pixel Buds. It is an RFCOMM channel, UUID `25e97ff7-24ce-4c4c-8951-f764a708f7b5`. The messages are pigweed RPC packets (protobuf) in HDLC frames. The app calls `maestro_pw.Maestro/SubscribeRuntimeInfo` and reads the battery info. This gives the case level when one or more buds are in the case. The open source tool [pbpctrl](https://github.com/qzed/pbpctrl) documents this protocol. The app opens Maestro each time it opens the Message Stream.
3. **BLE Battery Service (iOS and macOS).** For buds that are connected to the device, the app reads the standard Battery Level characteristic (`0x2A19`) if the buds have it. This gives one level for the buds, not left, right, and case.
4. **Fast Pair BLE advertisement (iOS and macOS).** The buds put service data for UUID `0xFE2C` in their BLE advertisements. The Fast Pair spec has a battery field in this data (field type 3 or 4). The app scans for this data with CoreBluetooth. **Pixel Buds Pro 2 do not send this field.** They send encrypted fields that only a device with the account key can read. The parser is strict: if a field type is unknown, or if the fields do not fill the data exactly, the app does not use the data. This prevents incorrect levels from encrypted bytes.

Spec: [Battery Notification](https://developers.google.com/nearby/fast-pair/specifications/extensions/batterynotification), [Message Stream](https://developers.google.com/nearby/fast-pair/specifications/extensions/messagestream), [Device Information](https://developers.google.com/nearby/fast-pair/specifications/extensions/deviceinformation).

## Read battery when the case opens (macOS)

This setting is on by default. You can change it in the window and in the menu bar panel.

When the buds are not connected to the Mac, and the app finds a Fast Pair advertisement with a strong signal (more than -75 dBm), the app does these steps:

1. It opens a Bluetooth connection to the paired buds. It does not connect audio.
2. It opens the Message Stream and Maestro channels, and reads the levels.
3. It closes the channels and the connection, so that the buds can go back to your phone. The connection stays open for 30 seconds or less.

The app tries one time in 2 minutes or less often. It does not try when the buds are already connected to the Mac. It tries only when exactly one paired Fast Pair device is on the Mac, because the advertisement does not show which buds sent it.

## Last known levels

After the buds disconnect, the app shows the last levels from the Message Stream for 6 hours. It shows them dimmed, with the text "Not connected. Last known levels". The menu bar then shows `Buds --`.

When a part is "unknown" in a new report, the app shows the last known level of that part with its age, for example `44% · 12 min ago`.

## Platform limits

- **iOS cannot open the Message Stream or Maestro.** iOS apps cannot open RFCOMM channels to Bluetooth Classic accessories. The only way is the External Accessory framework, and it works only with MFi accessories. Pixel Buds are not MFi.
- **On iOS, Pixel Buds Pro 2 levels are not available.** The iOS app can only use the advertisement and the BLE Battery Service. The Pro 2 encrypt the battery data in the advertisement. iOS also does not let apps read the level that it shows in its own Batteries widget.
- **iOS scans in the foreground only.**
- **macOS needs the buds to be paired with the Mac.** For live data, connect the buds to the Mac, or keep "Read battery when the case opens" on.

## Logs

The app writes logs with `os.Logger`. To see them:

```bash
log stream --predicate 'subsystem == "com.example.PixelBudsBattery"' --level debug
```

Raw advertisement data and raw stream messages are at the debug level.

## Build

Needs Xcode 16 or later. Open `PixelBudsBattery.xcodeproj`. Select the `PixelBudsBattery` scheme. Then select "My Mac" or your iPhone as the run destination.

- For an iPhone, set your team in Signing & Capabilities. Change `PRODUCT_BUNDLE_IDENTIFIER` (now `com.example.PixelBudsBattery`) to a value of your own.
- To build a Mac app that you can run on your own Mac without a team, use ad-hoc signing:

```bash
xcodebuild -project PixelBudsBattery.xcodeproj -scheme PixelBudsBattery -configuration Release -destination 'platform=macOS' -derivedDataPath build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

- BLE scanning does not work in the iOS Simulator. Use a real iPhone.
- The first time the app starts, macOS or iOS asks for Bluetooth access. Allow it.

## Files

- `BatteryModels.swift`: data types, logging, the advertisement parser, and the Message Stream parser.
- `FastPairAdvertisementScanner.swift`: CoreBluetooth scan for `0xFE2C` service data.
- `GATTBatteryClient.swift`: reads the BLE Battery Service of connected buds.
- `MessageStreamClient.swift`: Message Stream client and "read battery when the case opens" (macOS only).
- `MaestroClient.swift`: minimal Maestro client for battery info (macOS only).
- `BatteryStore.swift`: merges the sources and keeps the last known levels.
- `ContentView.swift`, `PixelBudsBatteryApp.swift`: the UI.
