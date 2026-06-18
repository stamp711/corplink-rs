# corplink-rs package.
#
# Hybrid Go + Rust build:
#   1. `libwg` is a Go static library (c-archive) built from the bundled
#      `libwg/wireguard-go` submodule (a fork of wireguard-go). It produces
#      libwg.a + libwg.h.
#   2. The Rust binary links against libwg.a and runs bindgen against libwg.h
#      (build.rs), so it needs libclang at build time.
#
# Purity / hashes:
#   * `src` is the flake's own tree (passed as `self`), so build it WITH the
#     submodule:  nix build '.?submodules=1'  -- no source hash to pin.
#   * Rust crates are resolved straight from the committed Cargo.lock
#     (`cargoLock.lockFile`), so there is no cargo hash either.
#   * The ONE unavoidable content hash is `goModules.vendorHash`: the Go
#     third-party deps (gvisor, x/crypto, ...) are ~16 MB and are NOT vendored
#     in this repo, so Nix fetches them in a fixed-output derivation. The hash
#     is deterministic; run a build once and paste the value Nix reports.
{
  lib,
  rustPlatform,
  buildGoModule,
  rustfmt,
  pkg-config,
  openssl,
  src,
  version ? "0.5.4",
}:
let
  goSrc = "${src}/libwg/wireguard-go";

  # Build libwg.a + libwg.h from the bundled wireguard-go fork.
  # Upstream Makefile target:
  #   CGO_ENABLED=1 go build -trimpath -buildmode=c-archive ./libwg
  # plus a generated `version.go` (package main, const Version) in the package.
  libwg = buildGoModule {
    pname = "corplink-libwg";
    inherit version;
    src = goSrc;

    # Deterministic content hash of the fetched Go module set. Replace with the
    # value `nix build` reports on first run (it prints got: sha256-...).
    vendorHash = "sha256-ihsFS2SuI1iqACHnJesgJD14k08XMsuwUGE8w+Mwl+k=";

    # We emit a C archive, not a Go binary.
    buildPhase = ''
      runHook preBuild
      # main.go references a `Version` const the Makefile would generate.
      printf 'package main\n\nconst Version = "%s"\n' "v${version}" > libwg/version.go
      CGO_ENABLED=1 go build -trimpath -buildmode=c-archive -o libwg.a ./libwg
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib
      cp libwg.a libwg.h $out/lib/
      runHook postInstall
    '';

    dontStrip = true;
  };
in
rustPlatform.buildRustPackage {
  pname = "corplink-rs";
  inherit version src;

  # Hashless: everything comes from the committed lockfile.
  cargoLock.lockFile = ../Cargo.lock;

  nativeBuildInputs = [
    rustPlatform.bindgenHook # provides libclang for build.rs / bindgen
    rustfmt
    pkg-config # for openssl-sys (reqwest -> native-tls)
  ];

  buildInputs = [ openssl ];

  # let openssl-sys find the nixpkgs openssl via pkg-config
  OPENSSL_NO_VENDOR = 1;

  # build.rs does: rustc-link-search=./libwg, rustc-link-lib=wg, and bindgen
  # against ./libwg/libwg.h. Drop the prebuilt archive + header where it looks.
  preBuild = ''
    mkdir -p libwg
    cp ${libwg}/lib/libwg.a libwg/libwg.a
    cp ${libwg}/lib/libwg.h libwg/libwg.h
  '';

  # The Go c-archive pulls in pthread/dl at final link time.
  NIX_LDFLAGS = "-lpthread -ldl";

  meta = {
    description = "Feilian (VeCorplink) enterprise VPN client written in Rust";
    homepage = "https://github.com/PinkD/corplink-rs";
    license = lib.licenses.gpl2Plus;
    mainProgram = "corplink-rs";
    platforms = lib.platforms.linux;
  };
}
