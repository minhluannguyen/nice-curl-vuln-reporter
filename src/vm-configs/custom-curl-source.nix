{ pkgs
, version
, url
, sha256
, tlsBackend ? "openssl"   # "openssl" | "gnutls" | "wolfssl" | null
, withLibpsl ? true
, withZlib ? true
, withBrotli ? false
, withZstd ? false
, withLibidn2 ? false
, withNghttp2 ? false
, enableShared ? true
, enableDebug ? false
, doCheck ? false
, disabledProtocols ? []   # e.g. [ "aws" "basic-auth" " bearer-auth" ]
, disabledFeatures ? []    # e.g. [ "feature1" "feature2" ] (currently unused, reserved for future)
, extraConfigureFlags ? []
}:

let
  inherit (pkgs) lib stdenv fetchurl pkg-config perl openssl gnutls wolfssl
                 zlib libpsl brotli zstd libidn2 nghttp2;

  tlsPkg =
    if tlsBackend == "openssl" then openssl
    else if tlsBackend == "gnutls" then gnutls
    else if tlsBackend == "wolfssl" then wolfssl
    else null;

  tlsFlag =
    if tlsBackend == "openssl" then "--with-openssl"
    else if tlsBackend == "gnutls" then "--with-gnutls"
    else if tlsBackend == "wolfssl" then "--with-wolfssl"
    else "--without-ssl";

  configureFlags =
    [
      tlsFlag
    ]
    ++ lib.optional (!withLibpsl)  "--without-libpsl"
    ++ lib.optional (!withZlib)    "--without-zlib"
    ++ lib.optional (!withBrotli)  "--without-brotli"
    ++ lib.optional (!withZstd)    "--without-zstd"
    ++ lib.optional (!withLibidn2) "--without-libidn2"
    ++ lib.optional (!withNghttp2) "--without-nghttp2"
    ++ lib.optional (!enableShared) "--disable-shared"
    ++ lib.optional enableDebug "--enable-debug"
    ++ map (p: "--disable-${p}") disabledProtocols
    ++ extraConfigureFlags;
in
stdenv.mkDerivation {
  pname = "curl-${version}";
  inherit version doCheck configureFlags;

  src = fetchurl {
    inherit url sha256;
  };

  nativeBuildInputs = [ pkg-config perl ];

  buildInputs =
    lib.optional (tlsPkg != null) tlsPkg
    ++ lib.optional withLibpsl libpsl
    ++ lib.optional withZlib zlib
    ++ lib.optional withBrotli brotli
    ++ lib.optional withZstd zstd
    ++ lib.optional withLibidn2 libidn2
    ++ lib.optional withNghttp2 nghttp2;
}