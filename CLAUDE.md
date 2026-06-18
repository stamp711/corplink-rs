# CLAUDE.md

Guidance for working in this repository.

## What this is

`corplink-rs` is a Rust client for **飞连 (Feilian / VeCorplink)**, ByteDance/Volcengine's
enterprise VPN, which is a modified WireGuard. The client authenticates against the
corporate Feilian backend, fetches a dynamically-provisioned WireGuard peer config, then
brings up a tunnel using an **embedded, patched `wireguard-go`** (`wg-corplink`).

Supports Linux, macOS, and Windows 10.

## Build

The Rust binary links against `libwg`, a static library built from the Go submodule at
`libwg/wireguard-go` (a fork: https://github.com/PinkD/wireguard-go, branch `libwg`).
**`libwg` must be built before `cargo build`** — `build.rs` runs `bindgen` against
`libwg/libwg.h` and links `./libwg/libwg.a` (`cargo:rustc-link-lib=wg`).

```bash
# 1. build libwg (needs Go >= 1.22, CGO_ENABLED, a C toolchain)
cd libwg && ./build.sh        # Linux/macOS  (build.ps1 on Windows)
                              # = git submodule update --init --recursive; make libwg
# 2. build the Rust binary
cargo build --release
```

Windows requires the **GNU** Rust toolchain (`rustup default stable-x86_64-pc-windows-gnu`),
MinGW GCC + make, plus `wintun.dll` at runtime (fetched by `scripts/setup.ps1`).

**Nix** (`flake.nix`, `nix/`): builds libwg + the Rust binary together. The submodule must
be present, so pass `?submodules=1`:

```bash
nix build '.?submodules=1#corplink-rs'   # -> ./result/bin/corplink-rs
nix develop '.?submodules=1'             # cargo/go/bindgen devshell
```

`nix/corplink-rs.nix` builds the Go c-archive (`buildGoModule`, `vendorHash`) and feeds
`libwg.a`/`libwg.h` into `buildRustPackage` via `preBuild`; `bindgenHook` supplies libclang.
Source is `self` (hashless, needs submodules), crates come from `Cargo.lock` (hashless); the
only pinned content hash is the Go `vendorHash`. `nix/module.nix` is the NixOS module
(systemd unit with `CAP_NET_ADMIN`). nixpkgs is pulled from flakehub (tarball, not the
GitHub API) and needs rustc >= 1.88.

CI: `.github/workflows/test.yml` (push to `test` branch) builds Windows;
`release.yml` handles releases. There is no unit-test suite — "test" here means the
release build compiles.

## Run

Needs **root (Linux/macOS) / Administrator (Windows)** to create the TUN device and edit
routes — *except* in SOCKS5/netstack mode, which is fully userspace.

```bash
corplink-rs config.json        # config path defaults to ./config.json
RUST_LOG=debug corplink-rs config.json   # logging is via env_logger / RUST_LOG
```

Config is JSON (no comments allowed despite README examples). The client **rewrites the
config file in place** to persist generated fields (wg keypair, device_id, resolved
`server`, login `state`). A sibling `cookies.json` holds the session cookie store.

## Architecture / module map (`src/`)

- **`main.rs`** — entry point. Loads config, privilege check (skipped in netstack mode),
  resolves company server, runs the connect loop, starts `wg-corplink`, pushes config via
  UAPI, then `tokio::select!`s on a shutdown signal vs. a handshake-timeout watchdog. On
  exit: disconnect VPN, logout (feilian_v1 only), stop wg, restore DNS. Handles SIGINT and
  (unix) SIGTERM so `docker stop`/systemd trigger graceful shutdown.
- **`client.rs`** (largest) — the Feilian API client. Login flows (password, email-code,
  LDAP, OIDC, Lark/feishu QR, feilian_v1), `connect_vpn` (list VPNs → ping/select →
  fetch peer info → build `WgConf`), disconnect, logout, OTP/2FA.
- **`config.rs`** — `Config` (the JSON file) and `WgConf` (the resolved wg parameters).
  Platform + strategy constants (`PLATFORM_*`, `STRATEGY_*`), `RouteMode` (split/full).
- **`api.rs`** — API endpoint URL templates and the `ApiName` enum; UA is hardcoded as
  `os=Android, version=2` (Android UA returns a TOTP token at login, avoiding a separate
  2FA step).
- **`resp.rs`** — serde response types (`Resp<T>` envelope, login/vpn/otp responses).
- **`wg.rs`** — FFI bridge to `libwg` (`startWg`, `startWgNetstack`, `uapi`, `stopWg`) and
  `UAPIClient`, which builds the WireGuard UAPI `set=1`/`get=1` strings and runs the
  handshake-timeout watchdog (`check_wg_connection`, 5-min threshold).
- **`dns.rs`** — `DNSManager`, per-OS via `cfg-if` (macOS `networksetup`; Linux swaps
  `/etc/resolv.conf` with a backup; Windows is a no-op).
- **`utils.rs`** — wg keypair gen (x25519-dalek), base32/base64/hex, feilian_v1 AES
  password encryption, and `subtract_cidr_from_cidr` (CIDR subtraction for
  `vpn_disallowed_routes`).
- **`totp.rs`** — TOTP code generation. **`template.rs`** — tinytemplate URL rendering.
  **`qrcode.rs`** — terminal QR rendering for Lark login. **`state.rs`** — `Init`/`Login`
  persisted login state.

## Key concepts when changing things

- **Two run modes.** Kernel TUN mode (default; needs root, sets system routes + optional
  DNS) vs. **netstack/SOCKS5 mode** (`socks5_listen` set): userspace gVisor netstack inside
  wg-go exposing a SOCKS5 proxy, no root/routes/DNS/interface. In netstack mode
  `interface_name`, `use_vpn_dns`, `auto_setup_routes` are inert; use
  `config_wg_netstack` (no `route=`/`address`/`up` UAPI ops).
- **Transport protocol.** Server advertises `protocol_mode` (1 = TCP, else UDP).
  `force_protocol` ("udp"/"tcp") overrides it; UDP is often much faster on lossy links
  (TCP-over-TCP collapse). The `protocol` int flows through `WgConf` into the FFI start
  call.
- **Route handling.** `route_mode` split/full picks the server route list;
  `vpn_disallowed_routes` are CIDR-subtracted from every route (and AllowedIPs).
- **FFI safety.** `wg.rs` crosses into Go via raw pointers/CStrings; the `uapi()` result
  pointer is freed with `libc::free`. Be careful with null bytes and ownership here.

## Conventions

- Errors use `anyhow` with `.context(...)`; `main` prints `{:#}` and exits `EPERM`.
- Exit codes: `EPERM=1`, `ENOENT=2`, `ETIMEDOUT=110` (handshake timeout).
- License is GPL-2.0-or-later; preserve headers.
</content>
</invoke>
