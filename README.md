# MX10Printer

MX10Printer is a lightweight iOS app for communicating with a thermal printer named MX10 over BLE. The project is designed to be developed on Windows in VS Code, while the actual Xcode build and simulator validation happen on a macOS GitHub Actions runner before device distribution through TestFlight.

## Goal

Build a minimal but production-ready BLE MVP for the MX10 printer, focusing on:

- Bluetooth discovery and connection
- MX10 protocol framing
- status requests
- paper feed
- row-by-row printing
- future text and image rendering

## Architecture

The app follows a clean separation of concerns:

- UI: SwiftUI screens and actions
- Printer: MX10 command builders and print workflow
- Protocol: MX10 packet framing and CRC logic
- Bluetooth transport: CoreBluetooth manager and connection lifecycle
- Utilities: shared helpers such as CRC8

## MX10 BLE details

Confirmed device and BLE settings from physical testing:

- Device name: MX10
- Primary service: AE30
- Write characteristic: AE01 (`Write Without Response`)
- Notify characteristic: AE02 (`Notify`)
- Additional discovered UUIDs were seen but are not used yet: AE03, AE04, AE05, AE10, AE3A, AE3B, AE3C

The communication path is expected to be:

- CoreBluetooth
- Service AE30
- Characteristic AE01
- MX10
- Notification stream on AE02 back to CoreBluetooth

## Confirmed protocol behavior

The printer uses a framed packet pattern:

```text
51 78 CMD 00 LEN_LO LEN_HI PAYLOAD CRC FF
```

CRC details:

- CRC-8
- polynomial: 0x07
- initial value: 0x00
- CRC computed only over payload bytes

Confirmed commands:

- Status request: `A3`
- Paper feed: `A1`
- Print row: `A2`

Confirmed physical examples:

- Status request: `5178A30001000000FF`
- Status response: `5178A30103000000B60BFF`
- Feed 16 steps: `5178A1000200100057FF`

## Windows development workflow

This project is built to work from Windows 10/11 in Visual Studio Code.

The local workflow is:

1. Edit Swift files in VS Code.
2. Keep protocol and business logic separated from UI code.
3. Use XcodeGen on macOS runners to generate the Xcode project.
4. Validate with GitHub Actions on macOS.

It is intentionally not assumed that Xcode or a local macOS environment is available in the developer workstation.

## GitHub Actions build workflow

The repository includes a GitHub Actions workflow in `.github/workflows/ios-build.yml` that runs on `macos-latest` and:

- checks out the repo
- prints the Xcode version
- installs XcodeGen
- runs `xcodegen generate`
- lists schemes
- runs unit tests
- builds the app for the iOS simulator without code signing

This is the validation environment before TestFlight deployment.

## TestFlight internal distribution

Internal TestFlight distribution uses the App Store Connect internal testing group named `Home`.

Distribution to `Home` is handled by App Store Connect with `Enable automatic distribution` on that internal group. The CI pipeline uploads builds and waits for App Store Connect processing to finish; it does not assign internal groups through Fastlane because App Store Connect rejects duplicate internal build assignment through the Fastlane/pilot group API.

The TestFlight workflow must remain internal-only: no external testing, no public links, no Beta App Review submission, and no App Store Review submission.

## iOS build environment

The app targets iOS 17.0 and is intended to be built on macOS runners. Local Windows development is for editing, testing logic, and preparing the project; the build itself is executed in CI.

## Development plan

- BLE MVP
- text printing
- image printing
- dithering
- TestFlight deployment

## Notes

- No Apple secrets are committed in the repository.
- Generated Xcode build artifacts are ignored.
- This codebase is intentionally structured to avoid guessing undocumented MX10 commands.
