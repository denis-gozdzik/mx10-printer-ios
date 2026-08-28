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

## Guardrail

Never guess undocumented MX10 commands. If a behavior is not confirmed or found in a trustworthy protocol implementation, label it as unverified.
