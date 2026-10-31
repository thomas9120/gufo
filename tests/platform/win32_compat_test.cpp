#include <dirent.h>
#include <fcntl.h>
#include <io.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <windows.h>
#include <winioctl.h>

#include <array>
#include <cassert>
#include <cerrno>
#include <filesystem>
#include <iostream>
#include <string>

#include "src/cache/disk.hpp"
#include "src/cache/ledger.hpp"

int main(int argc, char** argv) {
  if (argc == 2 && std::string(argv[1]) == "child token with spaces")
    return 23;
  std::cout << "win32_compat_test: madvise populate\n" << std::flush;
  {
    // A faulting page must fail the call with EFAULT rather than crash.
    constexpr size_t kPage = 4096;
    auto* region = static_cast<char*>(VirtualAlloc(
        nullptr, 8 * kPage, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
    assert(region);
    assert(madvise(region, 8 * kPage, MADV_POPULATE_READ) == 0);
    DWORD previous{};
    assert(VirtualProtect(region + 5 * kPage, kPage, PAGE_NOACCESS, &previous));
    errno = 0;
    assert(madvise(region, 8 * kPage, MADV_POPULATE_READ) == -1 &&
           errno == EFAULT);
    assert(VirtualFree(region, 0, MEM_RELEASE));
  }
  std::cout << "win32_compat_test: spawn/wait\n" << std::flush;
  pid_t child{};
  char token[] = "child token with spaces";
  char* arguments[]{argv[0], token, nullptr};
  assert(posix_spawn(&child, argv[0], nullptr, nullptr, arguments, nullptr) ==
         0);
  int status{};
  assert(waitpid(child, &status, 0) == child);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 23);
  std::cout << "win32_compat_test: directory operations\n" << std::flush;
  const auto path = std::filesystem::temp_directory_path() /
                    ("gufo-win32-" + std::to_string(getpid()));
  std::filesystem::remove_all(path);
  std::filesystem::create_directory(path);
  gufo::cache::ResourceLedger ledger(
      {1024 * 1024, 1024 * 1024, 1024 * 1024, 1024 * 1024});
  {
    gufo::cache::DiskStore store(ledger, path / "private-cache", 1024 * 1024);
    assert(store.Entries().empty());
  }
  const int root = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  assert(root >= 0);
  assert(mkdirat(root, "spaced directory", 0700) == 0);
  assert(mkdirat(root, "spaced directory", 0700) < 0 && errno == EEXIST);
  const char unicode_name[] = "unicode-\xc3\xa9";
  assert(mkdirat(root, unicode_name, 0700) == 0);
  const int file = openat(root, "source", O_RDWR | O_CREAT | O_EXCL, 0600);
  assert(file >= 0);
  const int contender = openat(root, "source", O_RDWR);
  assert(contender >= 0);
  std::cout << "win32_compat_test: locks\n" << std::flush;
  assert(flock(file, LOCK_EX | LOCK_NB) == 0);
  assert(flock(contender, LOCK_EX | LOCK_NB) < 0 && errno == EWOULDBLOCK);
  assert(flock(file, LOCK_UN) == 0);
  assert(flock(contender, LOCK_EX | LOCK_NB) == 0);
  assert(close(contender) == 0);
  std::cout << "win32_compat_test: sparse large-offset I/O\n" << std::flush;
  // Exercise 64-bit offsets without zeroing/flushing 4 GiB on hosted disks.
  // Keep production pwrite/pread/fsync unchanged; only this fixture is sparse.
  const auto handle = reinterpret_cast<HANDLE>(_get_osfhandle(file));
  DWORD returned{};
  assert(DeviceIoControl(handle, FSCTL_SET_SPARSE, nullptr, 0, nullptr, 0,
                         &returned, nullptr));
  constexpr off_t offset = (off_t{1} << 32) + 7;
  const std::array<char, 4> bytes{'g', 'u', 'f', 'o'};
  assert(pwrite(file, bytes.data(), bytes.size(), offset) == 4);
  std::array<char, 4> read_bytes{};
  assert(pread(file, read_bytes.data(), read_bytes.size(), offset) == 4);
  assert(bytes == read_bytes);
  assert(fsync(file) == 0);
  struct stat before{};
  assert(fstat(file, &before) == 0 && before.st_size == offset + 4);
  FILE_STANDARD_INFO allocation{};
  assert(GetFileInformationByHandleEx(handle, FileStandardInfo, &allocation,
                                      sizeof(allocation)));
  assert(allocation.AllocationSize.QuadPart <= 1024 * 1024);
  read_bytes.fill(1);
  assert(pread(file, read_bytes.data(), read_bytes.size(), offset - 4) == 4);
  assert((read_bytes == std::array<char, 4>{}));
  std::cout << "win32_compat_test: rename/enumeration\n" << std::flush;
  assert(gufo_rename_noreplace(root, "source", root, "target") == 0);
  const int replacement =
      openat(root, "source", O_RDWR | O_CREAT | O_EXCL, 0600);
  assert(replacement >= 0);
  assert(gufo_rename_noreplace(root, "source", root, "target") < 0 &&
         errno == EEXIST);
  struct stat after{};
  assert(fstatat(root, "target", &after, 0) == 0);
  assert(before.st_ino == after.st_ino && before.st_dev == after.st_dev);
  const int copy = openat(root, ".", O_RDONLY | O_DIRECTORY);
  assert(copy >= 0);
  DIR* directory = fdopendir(copy);
  assert(directory);
  bool found = false;
  bool found_unicode = false;
  errno = 0;
  while (const auto* entry = readdir(directory)) {
    found |= std::string(entry->d_name) == "spaced directory";
    found_unicode |= std::string(entry->d_name) == unicode_name;
  }
  assert(errno == 0 && found && found_unicode);
  assert(closedir(directory) == 0);
  std::cout << "win32_compat_test: directory flush/cleanup\n" << std::flush;
  assert(fsync(root) == 0);  // Native writable directory handle flush.
  assert(close(replacement) == 0);
  assert(close(file) == 0);
  assert(close(root) == 0);
  std::filesystem::remove_all(path);
}
