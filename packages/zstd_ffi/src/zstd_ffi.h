#ifndef ZSTD_FFI_H
#define ZSTD_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

/* Result codes returned by the zstd wrapper. */
#define ZSTD_FFI_OK 0
#define ZSTD_FFI_ERR_INIT (-8001)
#define ZSTD_FFI_ERR_PARAM (-8002)
#define ZSTD_FFI_ERR_STREAM (-8003)

/* The native library was built without the vendored libzstd sources. */
#define ZSTD_FFI_ERR_LIB_UNAVAILABLE (-6000)

/* ---- Compression ---- */

/* Creates a streaming compression context at the given level (1..22, or 0 for
 * the library default). When workers > 0 and the library was built with
 * multithreading, compression is spread across that many worker threads
 * (ZSTD_c_nbWorkers); otherwise it degrades safely to single-threaded. Returns
 * an opaque handle, or NULL on failure. */
FFI_PLUGIN_EXPORT void *zstd_cctx_create(int level, int workers);

/* Frees a compression context created by zstd_cctx_create. */
FFI_PLUGIN_EXPORT void zstd_cctx_free(void *ctx);

/* Pushes up to in_len bytes from in_ptr through the compressor and writes up to
 * out_cap bytes to out_ptr. *in_consumed and *out_produced report the bytes
 * actually consumed/produced. When finish is non-zero the stream is flushed and
 * ended; *finished is set to 1 once the end frame is fully written (it may take
 * several calls with empty input to drain). Returns ZSTD_FFI_OK on success. */
FFI_PLUGIN_EXPORT int zstd_compress_stream(void *ctx,
                                           const uint8_t *in_ptr, size_t in_len,
                                           size_t *in_consumed,
                                           uint8_t *out_ptr, size_t out_cap,
                                           size_t *out_produced,
                                           int finish, int *finished);

/* ---- Decompression ---- */

/* Creates a streaming decompression context. Returns an opaque handle, or NULL
 * on failure. */
FFI_PLUGIN_EXPORT void *zstd_dctx_create(void);

/* Frees a decompression context created by zstd_dctx_create. */
FFI_PLUGIN_EXPORT void zstd_dctx_free(void *ctx);

/* Pushes up to in_len bytes from in_ptr through the decompressor and writes up
 * to out_cap bytes to out_ptr. *in_consumed and *out_produced report the bytes
 * actually consumed/produced. *finished is set to 1 when a frame boundary has
 * been reached and no more output is pending. Returns ZSTD_FFI_OK on success. */
FFI_PLUGIN_EXPORT int zstd_decompress_stream(void *ctx,
                                             const uint8_t *in_ptr, size_t in_len,
                                             size_t *in_consumed,
                                             uint8_t *out_ptr, size_t out_cap,
                                             size_t *out_produced,
                                             int *finished);

/* Recommended buffer sizes (0 when the library is unavailable). */
FFI_PLUGIN_EXPORT size_t zstd_cstream_in_size(void);
FFI_PLUGIN_EXPORT size_t zstd_cstream_out_size(void);
FFI_PLUGIN_EXPORT size_t zstd_dstream_in_size(void);
FFI_PLUGIN_EXPORT size_t zstd_dstream_out_size(void);

#ifdef __cplusplus
}
#endif

#endif /* ZSTD_FFI_H */
