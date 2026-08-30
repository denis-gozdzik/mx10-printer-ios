# AGENTS.md

This project records the verified MX10 printer behavior used by the application. The implementation intentionally avoids guessing undocumented packet formats, BLE behavior, or printer commands.

## Verified MX10 device facts

- BLE device name: MX10
- Printer width: 384 px
- One monochrome print row is 48 bytes
- One A2 row frame is 56 bytes: 48 payload bytes plus 8 protocol framing bytes
- Advertised service UUID: AF30
- Connected protocol service UUID: AE30
- AF30 is the confirmed advertised service.
- AE30 is the confirmed connected protocol service.
- Write characteristic UUID: AE01 (`Write Without Response`)
- Notify characteristic UUID: AE02 (`Notify`)
- Additional discovered UUIDs: AE03, AE04, AE05, AE10, AE3A, AE3B, AE3C
- Intended transport path: CoreBluetooth -> AE30 -> AE01 -> MX10 -> AE02 -> CoreBluetooth
- Physical iPhone testing observed `maximumWriteValueLength(for: .withoutResponse) = 20` immediately after connection, but later during a real print session CoreBluetooth reported `245` and accepted complete 56-byte A2 frames.
- Build 11 completed multiple physical print jobs on real MX10 hardware, including full 640/640 sessions with readable text output.
- The app must query the current CoreBluetooth write-without-response length at print start and send time. Do not permanently rely on the immediate post-connect value.

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

The CRC is calculated only over payload bytes. A complete logical MX10 frame must be written atomically when the current CoreBluetooth write-without-response maximum can fit it. Do not split, recalculate CRC, or append extra terminators inside `MX10Protocol`.

## Verified commands

- Status request: `A3`
- Manual paper feed: `A1`
- Print row: `A2`
- Quality command in the working print session: `A4 32`
- Energy command in the working print session: `AF FF FF`
- Apply energy command in the working print session: `BE 01`
- Lattice start/end commands: `A6`
- Session feed command in the working print session: `BD 00`
- Set-paper command in the working print session: `A1 30 00`

Verified examples:

- Request status: `5178A30001000000FF`
- Response status: `5178A30103000000B60BFF`
- Feed 16 steps: `5178A1000200100057FF`

## Build 11 verified print session

The following exact current session has successfully produced readable output on the physical MX10:

```text
A3
A4 32
AF FF FF
BE 01
A6 lattice start
A2 raster rows
BD 00
A1 30 00
A6 lattice end
A3
```

This verifies that this exact sequence works on this physical MX10. It does not prove every semantic interpretation of each command or every possible command value.

Additional build-11 facts:

- The app's MSB-first internal raster, bit-reversed for MX10 A2 wire format, produced readable text.
- Full 56-byte A2 writes work when the live CoreBluetooth write-without-response maximum is 245.
- 20 ms inter-packet pacing is the current stable baseline.
- The original manually verified feed command remains `A1` with two little-endian step bytes; 16 steps is `5178A1000200100057FF`.

## Width and bitmap rules

- Print width: 384 pixels
- 48 bytes per row in monochrome mode
- A row of 48 bytes with `0xFF` was observed to physically print a black line
- Physical print jobs trim trailing all-white raster rows while preserving leading whitespace and 24 trailing white rows as bottom margin.

## Diagnostic logging rules

- All BLE, queue, render, raster, protocol, printer, image, editor, app, and error diagnostics must go through `DiagnosticLogger`.
- The logger keeps a bounded 5000-entry ring buffer and persists the latest log locally as UTF-8 text.
- Do not log Apple API keys, GitHub PATs, match passwords, certificates, or private signing material.
- Raster row logging must summarize ordinary bitmap rows. Full HEX is allowed for initialization/status/control commands, the first three bitmap rows, the last three bitmap rows, and failures.
- BLE write logging must include cached and current write-without-response lengths, logical `frameBytes`, row/frame backpressure, and `peripheralIsReady` resume row/frame context.
- Print jobs must expose a lifecycle of `queued`, `rendering`, `ready`, `sending`, `completed`, `failed`, or `cancelled`.
- `PrintQueue` must return to an idle/usable state after success, failure, timeout, cancellation, or disconnect.
- `peripheralIsReady(toSendWriteWithoutResponse:)` only wakes the suspended sender. It must not update row progress or bytes sent.
- The default print threshold is 128. A different diagnostic threshold value is a persisted user preference unless an explicit migration changes it; do not reset persisted print preferences during BLE work.

## Architecture rules

- UI must not own BLE logic.
- The printer layer must not embed magic UUIDs or protocol frames in UI views.
- BLE transport stays inside the Bluetooth manager.
- Protocol building and validation stay in the MX10 protocol layer.
- Localization and future rendering features add on top of the protocol layer.

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
