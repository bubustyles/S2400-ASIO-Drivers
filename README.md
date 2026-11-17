# S2400 ASIO Drivers

Windows drivers and tools for the **ISLA S2400**: use the S2400 as a real ASIO® device in your audio software (DAW), combine it with your audio interface, and feed samples into it.

> **Private project, Windows only, no support.** I wrote this for my own studio and am sharing it in case it is useful to others. It is not a product of ISLA Instruments and is not supported by them.

## Download

Get the installer from the [Releases page](https://github.com/bubustyles/S2400-ASIO-Drivers/releases). It comes with a manual in English and German (PDF).

Requirements: Windows 10/11 (64-bit), ISLA S2400 connected via USB. For the aggregate you also need another ASIO device (your audio interface) as clock master.

## What's included

| Part | What it does |
|---|---|
| **S2400 ASIO Driver** | The S2400 on its own as an ASIO device (Kernel Streaming): 10 inputs, 2 outputs. |
| **S2400 Aggregate** | One ASIO device made of your audio interface (clock master), the S2400 (follows the master's clock) and, optionally, a Windows output. |
| **S2400 Monitor** | Tray helper that keeps the aggregate open, so you can hear the S2400 through your interface without a DAW running. |
| **S2400 Isla-Mixer** | Level, pan and routing of the S2400 channels to the master's outputs. |
| **S2400 Zuspieler** (feeder) | Plays samples and loops through a second sound card into line 1&2 of the S2400 for sampling: up to 8 tracks, turntable speeds, pitch, tempo, slicing into single hits, saving everything as a stack. |

The user interface is available in English and German.

## Building from source

The code is written in **Delphi** (Object Pascal), 64-bit.

1. Open `S2400Asio.groupproj` in Delphi (built with Delphi 13; VCL, Win64).
2. Build all five projects in the **Release / Win64** configuration. The output goes to `Win64\Release`.
3. Optional: build the manual with `python Handbuch\build_handbuch.py <version>` (needs Microsoft Edge for PDF output).
4. Optional: build the installer with Inno Setup 7 from `S2400Setup.iss`.

The ASIO interface definition (`AsioInterface.pas`) is a Delphi translation of the headers from the Steinberg ASIO SDK 2.3, which is used under the GPLv3 option of its license.

## License

Copyright (C) 2026 David Ritter

This program is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License, version 3**, as published by the Free Software Foundation. It is distributed in the hope that it will be useful, but **without any warranty**; without even the implied warranty of merchantability or fitness for a particular purpose. See [LICENSE](LICENSE) for details.

There is no support, no entitlement to updates and no liability beyond what the law requires. Use it at your own risk and turn your monitors down the first time you start it.

## Trademarks

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/asio-compatible-white.png">
  <img src="docs/asio-compatible-bw.png" alt="ASIO Compatible" height="48">
</picture>

ASIO is a registered trademark of Steinberg Media Technologies GmbH.

ISLA Instruments and S2400 are trademarks of their respective owners. All other names belong to their owners.
