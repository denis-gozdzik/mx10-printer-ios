# AGENTS.md

This project records the verified MX10 printer behavior used by the application. The implementation intentionally avoids guessing undocumented packet formats, BLE behavior, or printer commands.

## Verified MX10 device facts

- BLE device name: MX10
- Printer width: 384 px
- One monochrome print row is 48 bytes
- Advertised service UUID: AF30
- Connected protocol service UUID: AE30
- AF30 is the confirmed advertised service.
- AE30 is the confirmed connected protocol service.
- Write characteristic UUID: AE01 (`Write Without Response`)
- Notify characteristic UUID: AE02 (`Notify`)
- Additional discovered UUIDs: AE03, AE04, AE05, AE10, AE3A, AE3B, AE3C
- Intended transport path: CoreBluetooth -> AE30 -> AE01 -> MX10 -> AE02 -> CoreBluetooth

## Verified protocol framing

The printer uses this raw frame format:

```text
51 78 CMD 00 LEN_LO LEN_HI PAYLOAD CRC FF
```

Where:

- `51 78` is the frame prefix
- `CMD` is the command byte
- `00` is the fixed byte after the command
- `LEN_LO` and `LEN_HI` define the payload length in little-endian order
- `PAYLOAD` contains the command data
- `CRC` is CRC-8 with polynomial `0x07`, initial value `0x00`
- `FF` is the frame terminator

The CRC is calculated only over payload bytes.

## Verified commands

- Status request: `A3`
- Paper feed: `A1`
- Print row: `A2`

Verified examples:

- Request status: `5178A30001000000FF`
- Response status: `5178A30103000000B60BFF`
- Feed 16 steps: `5178A1000200100057FF`

## Width and bitmap rules

- Print width: 384 pixels
- 48 bytes per row in monochrome mode
- A row of 48 bytes with `0xFF` was observed to physically print a black line

## Diagnostic logging rules

- All BLE, queue, render, raster, protocol, printer, image, editor, app, and error diagnostics must go through `DiagnosticLogger`.
- The logger keeps a bounded 5000-entry ring buffer and persists the latest log locally as UTF-8 text.
- Do not log Apple API keys, GitHub PATs, match passwords, certificates, or private signing material.
- Raster row logging must summarize ordinary bitmap rows. Full HEX is allowed for initialization/status/control commands, the first three bitmap rows, the last three bitmap rows, and failures.
- Print jobs must expose a lifecycle of `queued`, `rendering`, `ready`, `sending`, `completed`, `failed`, or `cancelled`.
- `PrintQueue` must return to an idle/usable state after success, failure, timeout, cancellation, or disconnect.

## Architecture rules

- UI must not own BLE logic.
- The printer layer must not embed magic UUIDs or protocol frames in UI views.
- BLE transport stays inside the Bluetooth manager.
- Protocol building and validation stay in the MX10 protocol layer.
- Localization and future rendering features add on top of the protocol layer.

## Unverified print-init command findings

These commands are reported by compatible `51 78 ... CRC FF` cat-printer implementations, but only `A1`, `A2`, and `A3` are physically verified on this MX10. Keep all unverified settings behind `MX10PrintConfiguration` / `MX10PrinterProfile` and do not send them by default.

| Command | Likely purpose | Payload notes | Confidence |
| --- | --- | --- | --- |
| `A8` | Device information request | one byte, often `00` | Medium, unverified on MX10 |
| `A3` | Device state request | one byte `00` | High, physically verified |
| `BB` | Device/model identifier or setup | one byte observed in captures | Low |
| `A4` | Quality/concentration | one byte, value mapping varies | Medium |
| `A6` | Lattice/start/end setup | reported 11-byte constants | Medium |
| `AF` | Thermal energy | little-endian UInt16 | Medium; do not vary blindly |
| `BE` | Print/drawing mode | one byte or variant-specific payload | Medium |
| `BD` | Feed/print speed | one byte, value mapping unknown | Medium |
| `BF` | Compressed row/control segment | four-byte capture examples; unclear | Low |

References used for this audit:

- `https://github.com/fulda1/Thermal_Printer/wiki/Cat-printer-protocol`
- `https://parzivail.github.io/ble-thermal-printer/`

## Build and runtime environment

- Windows does not include Xcode.
- Xcode project generation is expected on macOS runner in GitHub Actions.
- The app is targeted at iOS 17.
- Physical printer testing takes place on iPhone + MX10 hardware.

## TestFlight distribution

- Internal testing group: Home
- Distribution mechanism: App Store Connect `Enable automatic distribution` on the `Home` internal group.
- CI uploads builds and waits for App Store Connect processing.
- Fastlane must not assign the `Home` internal group directly; internal group assignment is handled by App Store Connect automatic distribution.
- TestFlight delivery must not enable external testing, public links, Beta App Review submission, or App Store Review submission.

## Guardrail

Never guess undocumented MX10 commands. If a behavior is not confirmed or found in a trustworthy protocol implementation, label it as unverified.
