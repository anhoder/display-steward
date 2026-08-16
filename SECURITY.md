# Security Policy

## Reporting a Vulnerability

Display Steward controls real display hardware and depends on the private CoreGraphics SPI `CGSConfigureDisplayEnabled`. Please report security issues privately before public disclosure.

Contact: anhoder@88.com

Include in the report:

- macOS version and hardware model
- steps to reproduce
- expected versus actual behavior

You should receive an acknowledgement within 7 days. Please do not create public issues for unverified vulnerabilities.

## Safety Model

Display Steward must never leave the user without a usable display:

- At least one active usable display is preserved; equal-priority disables prefer the current main display, then a built-in display, then stable identity order.
- Disables are journaled before commit, the global active-display postcondition is verified after every transaction, and committed uncertainty remains recoverable.
- The private SPI is confined to `DisplayActionAdapter.swift` in a single session transaction with topology verification before and after every operation. If the SPI disappears or changes behavior on a macOS release, unsafe automation is disabled and the limitation is surfaced rather than hidden.

## Supported Versions

Only the latest release is supported. Use the release matching your macOS version (macOS 13 or later).
