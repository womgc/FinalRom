# chdman_ffi

FFI plugin that wraps MAME's CHD ("chdman") library so the app can **create**
and **extract** CD CHD images (`.cue`/`.bin`/`.gdi`/`.iso` ↔ `.chd`). Supports
Android, iOS, Linux, macOS, and Windows.

## Vendoring the MAME chd sources

The MAME chd library is **not** bundled. Before building with real CHD support,
drop the chd source subset and the codec libraries into `src/chd/` as described
in [`src/chd/PLACEHOLDER.md`](src/chd/PLACEHOLDER.md).

Until then the plugin builds a stub: `chdmanCreateCd` / `chdmanExtractCd` return
`ChdmanResult.errLibUnavailable` and the app reports that CHD support is not
built. The rest of the app is unaffected.

## Usage

```dart
import 'package:chdman_ffi/chdman_ffi.dart';

final code = chdmanCreateCd(inputCuePath, outputChdPath, force: false);
if (code != ChdmanResult.ok) {
  // handle error
}
```

The native calls are synchronous and blocking — run them off the UI isolate.
