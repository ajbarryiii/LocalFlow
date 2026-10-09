# LocalFlow for iPhone (prototype)

A custom keyboard with a dictation button, backed by the bundled Parakeet model
running in the containing app. [ARCHITECTURE.md](ARCHITECTURE.md) is the
contract between the components. Like the macOS app, it builds with `swiftc`
and `make` only, with no Xcode project and no Swift Package Manager.

## Requirements

- A Mac with Xcode 26 or newer (iOS 26 SDK) and an iOS 26 simulator runtime.
- `python3` (Xcode provides `/usr/bin/python3`), used to relabel the model.
- A Parakeet model bundle (`PARAKEET_BUNDLE_DIR`) to transcribe. Weights stay
  outside Git and are copied only into the local build.

## Build and check

Run from the repository root (or `make <target>` inside `iOS/`):

```bash
make -C iOS                      # build/simulator/LocalFlow.app, no model
make -C iOS PARAKEET_BUNDLE_DIR=/path/to/bundle   # with the model in LocalFlow.app/Parakeet/
make -C iOS check                # simulator type-check, host tests, plutil -lint
```

The app contains `PlugIns/LocalFlowKeyboard.appex`. Repeat builds keep an
unchanged copy of the 330 MB model instead of copying it again.

| Variable | Default | Purpose |
| --- | --- | --- |
| `PLATFORM` | `simulator` | `simulator` or `device` (arm64 only) |
| `BUNDLE_ID` | `com.ajbarryiii.localflow.ios.dev` | app ID; the keyboard is `$(BUNDLE_ID).keyboard` |
| `APP_GROUP` | `group.$(BUNDLE_ID)` | shared container for app and keyboard |
| `URL_SCHEME` | `localflow-dev` | `<scheme>://dictate` |
| `DISPLAY_NAME` | `LocalFlow Dev` | home screen and keyboard list name |
| `DEPLOYMENT_TARGET` | `26.0` | the encoder uses the `ios19` Core ML opset |
| `PARAKEET_BUNDLE_DIR` | empty | model bundle to embed |
| `BUILD_DIR` | `build/$(PLATFORM)` | output directory |
| `SWIFT_FLAGS` | empty | extra compiler flags, e.g. `-D LOCALFLOW_SELFTEST` |
| `CODESIGN_IDENTITY`, `TEAM_ID`, `APP_PROFILE`, `KEYBOARD_PROFILE` | `-` on the simulator | device signing |

Source lists (`APP_SWIFT_SOURCES`, `KEYBOARD_SWIFT_SOURCES`, `SHARED_SOURCES`,
`HOSTCORE_SOURCES`, `TEST_SOURCES`, `PARAKEET_SOURCES`) can be overridden, for
example `make -C iOS check SHARED_SOURCES= HOSTCORE_SOURCES=`.

## Simulator

```bash
make -C iOS install-sim          # builds, creates/boots LocalFlow-Smoke, installs
make -C iOS run-sim              # also opens Simulator and launches the app
```

`SIM_DEVICE` (default `LocalFlow-Smoke`) is created on first use with
`SIM_DEVICE_TYPE` (default `iPhone 17 Pro`) and `SIM_RUNTIME` (default: the
newest installed iOS runtime). To enable the keyboard in the simulator, open
Settings → General → Keyboard → Keyboards → Add New Keyboard → LocalFlow Dev,
then turn on Allow Full Access.

Simulator builds are ad-hoc signed. As in Xcode simulator builds, the App
Group entitlement is embedded in each executable's `__TEXT,__entitlements` and
`__TEXT,__ents_der` sections.

### Smoke test

```bash
make -C iOS smoke-sim PARAKEET_BUNDLE_DIR=/path/to/bundle
```

This builds the self-test variant (`-D LOCALFLOW_SELFTEST`) into
`build/smoke-simulator`, installs it on `SIM_DEVICE`, and synthesizes an
invented phrase with `say`. It copies the WAV into the app's data container and
launches the app. The app checks that the App Group container is writable,
prepares the model, transcribes the samples, and prints one line:

```
LocalFlow self-test: result=pass stage=done transcript_match=true app_group=usable compute=cpuAndNeuralEngine preparation_s=… transcription_s=… audio_s=… peak_footprint_mb=… available_devices=… error=none
```

The transcript is never printed. The audio file is deleted afterwards. The log
is kept in `build/smoke-simulator/obj/selftest.log` only on failure. If
`smoke-sim` booted the simulator, it shuts it down again. Options:
`SMOKE_COMPUTE=cpuOnly`, `SMOKE_PHRASE`, `SMOKE_TIMEOUT` (seconds, default
900). Remove the device with `xcrun simctl delete LocalFlow-Smoke`.

The simulator has no Neural Engine. Core ML runs a `.cpuAndNeuralEngine` model
on the CPU there, so simulator timings say nothing about device performance.

## Device

Device builds need a paid developer team, because the App Group capability
requires explicit App IDs and provisioning profiles:

1. In the developer portal, register an App Group (`APP_GROUP`) and two
   explicit App IDs, `BUNDLE_ID` and `BUNDLE_ID.keyboard`, each with the App
   Groups capability set to that group.
2. Create a development provisioning profile for each App ID that includes
   your device, and download both.
3. Build and sign:

   ```bash
   make -C iOS PLATFORM=device PARAKEET_BUNDLE_DIR=/path/to/bundle \
     CODESIGN_IDENTITY="Apple Development: Name (XXXXXXXXXX)" TEAM_ID=XXXXXXXXXX \
     APP_PROFILE=/path/to/app.mobileprovision KEYBOARD_PROFILE=/path/to/keyboard.mobileprovision
   ```

   The build checks that each profile matches its App ID and grants the App
   Group. It then embeds the profiles, adds `application-identifier`,
   `com.apple.developer.team-identifier` and the profile's `get-task-allow`
   value to the entitlements, and signs the extension before the app.
4. Install with `xcrun devicectl device install app --device <device>
   iOS/build/device/LocalFlow.app`.

`make -C iOS PLATFORM=device binaries` compiles and links for the device
without signing.

## Manual tests

Pending. These need a device or a person at the simulator. Record results
before merge.

- [ ] Keyboard appears in Settings, can be enabled, and Full Access can be granted.
- [ ] App Group container is shared by the app and the keyboard on a device.
- [ ] Device-signed build installs and launches.
- [ ] Model preparation and transcription on a device (Neural Engine and CPU only).
