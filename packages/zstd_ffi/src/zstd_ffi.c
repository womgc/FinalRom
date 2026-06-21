/*
 * Thin C-ABI wrapper around libzstd's streaming API so Zstandard compression
 * and decompression can be driven from Dart via dart:ffi over caller-owned
 * buffers (NCAs are multi-GB, so nothing is buffered whole in native code).
 *
 * The libzstd sources are NOT bundled. Drop them into ./zstd as described in
 * zstd/PLACEHOLDER.md (or point the CMake at a system libzstd). When present,
 * the CMake build defines ZSTD_AVAILABLE and the real implementation is
 * compiled; otherwise a stub is built that reports ZSTD_FFI_ERR_LIB_UNAVAILABLE
 * so the host application still builds and links.
 */

#include "zstd_ffi.h"

#ifdef ZSTD_AVAILABLE

#include <zstd.h>

void *zstd_cctx_create(int level, int workers) {
  ZSTD_CCtx *ctx = ZSTD_createCCtx();
  if (ctx == NULL) {
    return NULL;
  }
  if (level != 0) {
    ZSTD_CCtx_setParameter(ctx, ZSTD_c_compressionLevel, level);
  }
  if (workers > 0) {
    // Ignored (returns an error we deliberately don't propagate) if the library
    // was built single-threaded, so this degrades safely to one thread.
    ZSTD_CCtx_setParameter(ctx, ZSTD_c_nbWorkers, workers);
  }
  return ctx;
}

void zstd_cctx_free(void *ctx) {
  if (ctx != NULL) {
    ZSTD_freeCCtx((ZSTD_CCtx *)ctx);
  }
}

int zstd_compress_stream(void *ctx,
                         const uint8_t *in_ptr, size_t in_len,
                         size_t *in_consumed,
                         uint8_t *out_ptr, size_t out_cap,
                         size_t *out_produced,
                         int finish, int *finished) {
  if (ctx == NULL || (in_ptr == NULL && in_len != 0) || out_ptr == NULL) {
    return ZSTD_FFI_ERR_PARAM;
  }

  ZSTD_inBuffer input = {in_ptr, in_len, 0};
  ZSTD_outBuffer output = {out_ptr, out_cap, 0};
  const ZSTD_EndDirective mode = finish ? ZSTD_e_end : ZSTD_e_continue;

  const size_t remaining =
      ZSTD_compressStream2((ZSTD_CCtx *)ctx, &output, &input, mode);

  if (ZSTD_isError(remaining)) {
    return ZSTD_FFI_ERR_STREAM;
  }

  if (in_consumed != NULL) *in_consumed = input.pos;
  if (out_produced != NULL) *out_produced = output.pos;
  // When finishing, remaining == 0 means the end frame is fully flushed.
  if (finished != NULL) *finished = (finish && remaining == 0) ? 1 : 0;
  return ZSTD_FFI_OK;
}

void *zstd_dctx_create(void) { return ZSTD_createDCtx(); }

void zstd_dctx_free(void *ctx) {
  if (ctx != NULL) {
    ZSTD_freeDCtx((ZSTD_DCtx *)ctx);
  }
}

int zstd_decompress_stream(void *ctx,
                           const uint8_t *in_ptr, size_t in_len,
                           size_t *in_consumed,
                           uint8_t *out_ptr, size_t out_cap,
                           size_t *out_produced,
                           int *finished) {
  if (ctx == NULL || (in_ptr == NULL && in_len != 0) || out_ptr == NULL) {
    return ZSTD_FFI_ERR_PARAM;
  }

  ZSTD_inBuffer input = {in_ptr, in_len, 0};
  ZSTD_outBuffer output = {out_ptr, out_cap, 0};

  const size_t ret =
      ZSTD_decompressStream((ZSTD_DCtx *)ctx, &output, &input);

  if (ZSTD_isError(ret)) {
    return ZSTD_FFI_ERR_STREAM;
  }

  if (in_consumed != NULL) *in_consumed = input.pos;
  if (out_produced != NULL) *out_produced = output.pos;
  // ret == 0 indicates a clean frame boundary with nothing buffered.
  if (finished != NULL) *finished = (ret == 0) ? 1 : 0;
  return ZSTD_FFI_OK;
}

size_t zstd_cstream_in_size(void) { return ZSTD_CStreamInSize(); }
size_t zstd_cstream_out_size(void) { return ZSTD_CStreamOutSize(); }
size_t zstd_dstream_in_size(void) { return ZSTD_DStreamInSize(); }
size_t zstd_dstream_out_size(void) { return ZSTD_DStreamOutSize(); }

#else /* !ZSTD_AVAILABLE */

void *zstd_cctx_create(int level, int workers) {
  (void)level;
  (void)workers;
  return NULL;
}

void zstd_cctx_free(void *ctx) { (void)ctx; }

int zstd_compress_stream(void *ctx,
                         const uint8_t *in_ptr, size_t in_len,
                         size_t *in_consumed,
                         uint8_t *out_ptr, size_t out_cap,
                         size_t *out_produced,
                         int finish, int *finished) {
  (void)ctx;
  (void)in_ptr;
  (void)in_len;
  (void)in_consumed;
  (void)out_ptr;
  (void)out_cap;
  (void)out_produced;
  (void)finish;
  (void)finished;
  return ZSTD_FFI_ERR_LIB_UNAVAILABLE;
}

void *zstd_dctx_create(void) { return NULL; }

void zstd_dctx_free(void *ctx) { (void)ctx; }

int zstd_decompress_stream(void *ctx,
                           const uint8_t *in_ptr, size_t in_len,
                           size_t *in_consumed,
                           uint8_t *out_ptr, size_t out_cap,
                           size_t *out_produced,
                           int *finished) {
  (void)ctx;
  (void)in_ptr;
  (void)in_len;
  (void)in_consumed;
  (void)out_ptr;
  (void)out_cap;
  (void)out_produced;
  (void)finished;
  return ZSTD_FFI_ERR_LIB_UNAVAILABLE;
}

size_t zstd_cstream_in_size(void) { return 0; }
size_t zstd_cstream_out_size(void) { return 0; }
size_t zstd_dstream_in_size(void) { return 0; }
size_t zstd_dstream_out_size(void) { return 0; }

#endif /* ZSTD_AVAILABLE */
