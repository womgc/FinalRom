# zstd_ffi

FFI plugin that wraps the native [Zstandard](https://github.com/facebook/zstd)
(`libzstd`) **streaming** compression API, so large payloads (e.g. Switch NCA
content for the NSZ feature) can be compressed/decompressed in chunks without
buffering whole files in native code. Supports Android, iOS, Linux, macOS, and
Windows.

## Vendoring the libzstd sources

The libzstd sources are **not** bundled. Drop the zstd source tree into
`src/zstd/` as described in [`src/zstd/PLACEHOLDER.md`](src/zstd/PLACEHOLDER.md).

Until then the plugin builds a stub: the stream functions return
`ZSTD_FFI_ERR_LIB_UNAVAILABLE` and the NSZ feature reports that Zstandard
support is not built.

## Usage

```dart
import 'package:zstd_ffi/zstd_ffi.dart';

final encoder = ZstdEncoder(level: 19);
try {
  final compressed = <int>[];
  compressed.addAll(encoder.process(chunk));      // feed chunks
  compressed.addAll(encoder.finish());            // flush + end
} finally {
  encoder.dispose();
}
```

The native calls are synchronous and blocking — run them off the UI isolate.
