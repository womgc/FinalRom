#ifndef XDELTA3_FFI_H
#define XDELTA3_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

/* Result codes. Negative xdelta3-internal codes may also be returned. */
#define XDELTA3_FFI_OK 0
#define XDELTA3_FFI_ERR_OPEN_PATCH (-5001)
#define XDELTA3_FFI_ERR_OPEN_ROM (-5002)
#define XDELTA3_FFI_ERR_OPEN_OUTPUT (-5003)
#define XDELTA3_FFI_ERR_WRONG_CHECKSUM (-5010)
#define XDELTA3_FFI_ERR_LIB_UNAVAILABLE (-6000)

/* Applies an xdelta3/VCDIFF patch at patch_path to rom_path, writing the
 * result to output_path. When ignore_checksum is non-zero, the source-window
 * Adler-32 verification is skipped. Returns XDELTA3_FFI_OK on success. */
FFI_PLUGIN_EXPORT int xdelta3_apply(const char *patch_path,
                                    const char *rom_path,
                                    const char *output_path,
                                    int ignore_checksum);

#ifdef __cplusplus
}
#endif

#endif /* XDELTA3_FFI_H */
