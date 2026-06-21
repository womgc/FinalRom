/*
 * Thin C-ABI wrapper around the xdelta3 single-file library so it can be
 * called from Dart via dart:ffi. The decode loop is adapted from UniPatcher's
 * JNI wrapper (app/src/main/cpp/xdelta3/xdelta3.c), with the JNI entry points
 * replaced by a plain exported function.
 *
 * The upstream xdelta3 sources are NOT bundled. Drop xdelta3.h and xdelta3.c
 * from https://github.com/jmacd/xdelta (xdelta3/ directory) into ./xdelta/.
 * When they are present, the CMake build defines XDELTA3_AVAILABLE and the real
 * implementation is compiled. Otherwise a stub is built that reports
 * XDELTA3_FFI_ERR_LIB_UNAVAILABLE so the host app still builds and links.
 */

#include "xdelta3_ffi.h"

#ifdef XDELTA3_AVAILABLE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* xdelta3 build configuration: must be set before including the headers. */
#if defined(_WIN64) || defined(__LP64__) || defined(__x86_64__) || defined(__aarch64__)
#define SIZEOF_SIZE_T 8
#else
#define SIZEOF_SIZE_T 4
#endif
#ifndef SIZEOF_UNSIGNED_LONG_LONG
#define SIZEOF_UNSIGNED_LONG_LONG 8
#endif

#include "xdelta/xdelta3.h"
#include "xdelta/xdelta3.c"

static int decode_stream(FILE *in, FILE *src, FILE *out, int ignore_checksum) {
  const int BUFFER_SIZE = 0x1000;

  int r, ret;
  xd3_stream stream;
  xd3_config config;
  xd3_source source;
  void *input_buf;
  int input_buf_read;

  memset(&stream, 0, sizeof(stream));
  memset(&source, 0, sizeof(source));

  xd3_init_config(&config, 0);
  config.winsize = BUFFER_SIZE;
  if (ignore_checksum) {
    config.flags |= XD3_ADLER32_NOVER;
  }
  xd3_config_stream(&stream, &config);

  source.blksize = BUFFER_SIZE;
  source.curblk = malloc(source.blksize);

  if (fseek(src, 0, SEEK_SET)) {
    free((void *)source.curblk);
    xd3_free_stream(&stream);
    return XDELTA3_FFI_ERR_OPEN_ROM;
  }
  source.onblk = fread((void *)source.curblk, 1, source.blksize, src);
  source.curblkno = 0;
  xd3_set_source(&stream, &source);

  input_buf = malloc(BUFFER_SIZE);
  fseek(in, 0, SEEK_SET);

  do {
    input_buf_read = fread(input_buf, 1, BUFFER_SIZE, in);
    if (input_buf_read < BUFFER_SIZE) {
      xd3_set_flags(&stream, XD3_FLUSH | stream.flags);
    }
    xd3_avail_input(&stream, input_buf, input_buf_read);

  process:
    ret = xd3_decode_input(&stream);

    switch (ret) {
      case XD3_INPUT:
        continue;

      case XD3_OUTPUT:
        r = fwrite(stream.next_out, 1, stream.avail_out, out);
        if (r != (int)stream.avail_out) {
          free(input_buf);
          free((void *)source.curblk);
          xd3_close_stream(&stream);
          xd3_free_stream(&stream);
          return XDELTA3_FFI_ERR_OPEN_OUTPUT;
        }
        xd3_consume_output(&stream);
        goto process;

      case XD3_GETSRCBLK:
        if (fseek(src, source.blksize * source.getblkno, SEEK_SET)) {
          free(input_buf);
          free((void *)source.curblk);
          xd3_close_stream(&stream);
          xd3_free_stream(&stream);
          return XDELTA3_FFI_ERR_OPEN_ROM;
        }
        source.onblk = fread((void *)source.curblk, 1, source.blksize, src);
        source.curblkno = source.getblkno;
        goto process;

      case XD3_GOTHEADER:
      case XD3_WINSTART:
      case XD3_WINFINISH:
        goto process;

      default:
        free(input_buf);
        free((void *)source.curblk);
        if (stream.msg != NULL &&
            strcmp(stream.msg, "target window checksum mismatch") == 0) {
          xd3_close_stream(&stream);
          xd3_free_stream(&stream);
          return XDELTA3_FFI_ERR_WRONG_CHECKSUM;
        }
        xd3_close_stream(&stream);
        xd3_free_stream(&stream);
        return ret;
    }
  } while (input_buf_read == BUFFER_SIZE);

  free(input_buf);
  free((void *)source.curblk);
  xd3_close_stream(&stream);
  xd3_free_stream(&stream);
  return XDELTA3_FFI_OK;
}

FFI_PLUGIN_EXPORT int xdelta3_apply(const char *patch_path,
                                    const char *rom_path,
                                    const char *output_path,
                                    int ignore_checksum) {
  FILE *patch = fopen(patch_path, "rb");
  if (!patch) {
    return XDELTA3_FFI_ERR_OPEN_PATCH;
  }
  FILE *rom = fopen(rom_path, "rb");
  if (!rom) {
    fclose(patch);
    return XDELTA3_FFI_ERR_OPEN_ROM;
  }
  FILE *out = fopen(output_path, "wb");
  if (!out) {
    fclose(patch);
    fclose(rom);
    return XDELTA3_FFI_ERR_OPEN_OUTPUT;
  }

  int ret = decode_stream(patch, rom, out, ignore_checksum);

  fclose(patch);
  fclose(rom);
  fclose(out);
  return ret;
}

#else /* !XDELTA3_AVAILABLE */

FFI_PLUGIN_EXPORT int xdelta3_apply(const char *patch_path,
                                    const char *rom_path,
                                    const char *output_path,
                                    int ignore_checksum) {
  (void)patch_path;
  (void)rom_path;
  (void)output_path;
  (void)ignore_checksum;
  return XDELTA3_FFI_ERR_LIB_UNAVAILABLE;
}

#endif /* XDELTA3_AVAILABLE */
