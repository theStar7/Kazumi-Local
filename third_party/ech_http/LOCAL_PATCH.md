# ech_http 0.2.3 local build patch

Source: https://pub.dev/packages/ech_http/versions/0.2.3

Upstream repository: https://github.com/ech-research/ech_http

Original pub.dev archive SHA-256: `7b179bbb0cba2f517d5f8fc526e6bb98d96530e6d7a75f7057fce74652967643`.

This directory preserves the published runtime sources (`lib`, `hook`, `src`),
package metadata, and license notices. Upstream examples, documentation, tools,
and tests are not needed by the application and are not included.

Only `src/CMakeLists.txt` and `src/ca_bundle.h.in` differ from the published
runtime sources. The original ~200 KB CA bundle was one raw string literal,
which fails with MSVC C2026 (single literal limit: 16380 bytes). The build now
generates a byte array and constructs the same `std::string` using its exact
length. The PEM file, dependency SDK verification, HTTP API, and TLS certificate
validation are unchanged. The byte array also avoids source-code page conversion
of the PEM contents.

The application selects this fixed version with a local path dependency. Pub
cache files and generated build files are not patched. Once an upstream release
fixes this issue, replace the local path dependency after verifying the fix.
