/*
 * Minimal stdio-backed implementation of MAME's osd_file abstraction, so the
 * vendored chd/cdrom code can do file I/O without pulling in MAME's per-OSD
 * file modules. Sufficient for chdman CD create/extract (sequential + seeked
 * reads/writes and truncate on the output CHD).
 */

#include "osdfile.h"

#include <cstdio>
#include <cstdlib>
#include <cerrno>
#include <new>
#include <string>

#if defined(_WIN32)
#include <io.h>
#define ftell64 _ftelli64
#define fseek64 _fseeki64
#define ftrunc(fd, len) _chsize_s((fd), (len))
#define fileno_portable _fileno
#else
#include <unistd.h>
#define ftell64 ftello
#define fseek64 fseeko
#define ftrunc(fd, len) ftruncate((fd), (len))
#define fileno_portable fileno
#endif

namespace {

class stdio_osd_file final : public osd_file {
 public:
  explicit stdio_osd_file(std::FILE *file) : m_file(file) {}
  ~stdio_osd_file() override {
    if (m_file) std::fclose(m_file);
  }

  std::error_condition read(void *buffer, std::uint64_t offset, std::uint32_t length,
                            std::uint32_t &actual) noexcept override {
    actual = 0;
    if (fseek64(m_file, (long long)offset, SEEK_SET) != 0)
      return std::error_condition(errno, std::generic_category());
    std::size_t const count = std::fread(buffer, 1, length, m_file);
    actual = std::uint32_t(count);
    if (count != length && std::ferror(m_file))
      return std::error_condition(errno, std::generic_category());
    return std::error_condition();
  }

  std::error_condition write(void const *buffer, std::uint64_t offset, std::uint32_t length,
                             std::uint32_t &actual) noexcept override {
    actual = 0;
    if (fseek64(m_file, (long long)offset, SEEK_SET) != 0)
      return std::error_condition(errno, std::generic_category());
    std::size_t const count = std::fwrite(buffer, 1, length, m_file);
    actual = std::uint32_t(count);
    if (count != length) return std::error_condition(errno, std::generic_category());
    return std::error_condition();
  }

  std::error_condition truncate(std::uint64_t offset) noexcept override {
    std::fflush(m_file);
    if (ftrunc(fileno_portable(m_file), (long long)offset) != 0)
      return std::error_condition(errno, std::generic_category());
    return std::error_condition();
  }

  std::error_condition flush() noexcept override {
    if (std::fflush(m_file) != 0) return std::error_condition(errno, std::generic_category());
    return std::error_condition();
  }

 private:
  std::FILE *m_file;
};

}  // namespace

std::error_condition osd_file::open(std::string const &path, std::uint32_t openflags, ptr &file,
                                    std::uint64_t &filesize) noexcept {
  const char *mode;
  const bool wants_write = (openflags & OPEN_FLAG_WRITE) != 0;
  const bool wants_create = (openflags & OPEN_FLAG_CREATE) != 0;

  std::FILE *fp = nullptr;
  if (!wants_write) {
    mode = "rb";
    fp = std::fopen(path.c_str(), mode);
  } else if (wants_create) {
    // Open for read+write, creating (and truncating) the file.
    fp = std::fopen(path.c_str(), "wb+");
  } else {
    // Open existing for read+write without truncating.
    fp = std::fopen(path.c_str(), "rb+");
  }
  if (!fp) return std::error_condition(errno ? errno : ENOENT, std::generic_category());

  fseek64(fp, 0, SEEK_END);
  long long const size = ftell64(fp);
  fseek64(fp, 0, SEEK_SET);
  filesize = (size < 0) ? 0 : std::uint64_t(size);

  file.reset(new (std::nothrow) stdio_osd_file(fp));
  if (!file) {
    std::fclose(fp);
    return std::errc::not_enough_memory;
  }
  return std::error_condition();
}

std::error_condition osd_file::openpty(ptr &file, std::string &name) noexcept {
  return std::errc::not_supported;
}

std::error_condition osd_file::remove(std::string const &filename) noexcept {
  if (std::remove(filename.c_str()) != 0)
    return std::error_condition(errno, std::generic_category());
  return std::error_condition();
}

// Minimal osd_getenv used by osdsync's work-queue sizing.
const char *osd_getenv(const char *name) { return std::getenv(name); }
