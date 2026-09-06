# Third-party notices

This project is written in Odin and uses the raylib bindings distributed with Odin.

## raylib

raylib is Copyright (c) 2013-2026 Ramon Santamaria (@raysan5) and contributors and is distributed under the zlib/libpng license.

Project: https://www.raylib.com/
Source: https://github.com/raysan5/raylib

## Odin

The Odin compiler and standard/vendor packages are developed by the Odin project and contributors. The compiler itself is a build-time dependency and is not bundled in these release archives.

Project: https://odin-lang.org/
Source: https://github.com/odin-lang/Odin

## libcurl

v1.2.0 uses the libcurl bindings distributed with Odin for HTTP/HTTPS rendezvous requests. libcurl is Copyright (c) Daniel Stenberg and contributors and is distributed under the curl license.

Project: https://curl.se/
Source: https://github.com/curl/curl

## mbed TLS / zlib

On Linux, Odin's `vendor:curl` package links the platform curl/mbed TLS/zlib libraries. mbed TLS is distributed under Apache-2.0 and zlib under the zlib license.

mbed TLS: https://github.com/Mbed-TLS/mbedtls
zlib: https://zlib.net/

The audio files in `assets/` were created specifically for this Pong project and are not third-party music or sound assets.


## Android v1.3+

The Android client builds raylib 6.0 from source for `arm64-v8a` using the Android NDK.
Rendezvous HTTPS on Android uses the platform `HttpURLConnection` API rather than libcurl.
