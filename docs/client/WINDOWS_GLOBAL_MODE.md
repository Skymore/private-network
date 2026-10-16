# Windows global mode

Connect 0.2.0 adds a Windows-only `tun` runtime mode. The existing account, encrypted
bundle and node protocol stay the same. macOS retains its system-proxy runtime.

## Runtime

The existing supervisor starts the bundled, unmodified sing-box 1.14.3 for `tun`,
and Xray for `system` and `manual`. Both expose the same loopback proxy ports.
The TUN configuration is generated from the selected ConnectionProfile; it captures
IPv4/IPv6 TCP and UDP, hijacks port 53, and sends DNS over HTTPS through the VLESS
outbound. LAN destinations stay direct. `auto_detect_interface` binds outbound
connections to the real network interface to avoid routing loops. The node hostname
is resolved before starting the tunnel. REALITY still authenticates its server name.

Windows requests elevation at app launch via its executable manifest. This version
does not install an additional privileged service. Consequently Windows asks for
administrator approval on every normal app launch, including system-proxy mode.
Standard Windows users need an administrator's credentials. Switching modes requires
disconnecting first. Credentials remain under the Windows user running the app.

Each core is assigned to a Windows kill-on-close Job Object. Normal disconnect kills
the core; a forced app exit also kills its core when Windows closes the Job handle.
The virtual adapter and its routes belong to the core. This is not a kill switch:
disconnecting or crashing restores direct connectivity.

Global account connections pin the selected node to manual selection to preserve
the exit IP. Reconnecting a failed connection uses the same node. A changed signed
bundle may still require a restart; existing game TCP sessions cannot survive that.

## Build and acceptance

`npm run prepare:tun` downloads the pinned upstream Windows archive; the existing
sidecar checksum policy also applies to this archive. Wintun is embedded in sing-tun.
The installer includes upstream notices. The upstream GPL source archive is published
beside the installer; sing-box is a separate, unmodified executable.

`.github/workflows/windows-tun.yml` builds and installs the actual NSIS package on
Windows. `run-windows-tun.ps1` starts a local REALITY server whose public test address
maps to a local TCP/UDP fixture. Raw sockets access that address without proxy APIs.
It also checks Windows DNS resolution through the tunnel, normal disconnect,
forced application termination and route cleanup. The test REALITY server binds its
internet outbound to the physical interface. A local TLS 1.3 fixture is the REALITY
handshake target, avoiding a dependency on a public site's TLS behavior during tests.
Ephemeral fixture credentials are discarded after the test.

These tests validate transport and cleanup. They do not run GMS or its anti-cheat.
GMS acceptance still requires login, entering a character, channel changes and a
long session on the friend's Windows machine.
