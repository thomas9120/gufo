#include <dirent.h>
#include <io.h>
#include <windows.h>

#include <cerrno>
#include <memory>
#include <vector>

struct gufo_directory {
  int fd{-1};
  HANDLE handle{INVALID_HANDLE_VALUE};
  std::vector<unsigned long long> buffer =
      std::vector<unsigned long long>(8192);
  DWORD offset{};
  bool first{true};
  bool refill{true};
  bool finished{};
  dirent entry{};
};

extern "C" DIR* fdopendir(int fd) {
  const auto handle = reinterpret_cast<HANDLE>(_get_osfhandle(fd));
  BY_HANDLE_FILE_INFORMATION info{};
  if (!GetFileInformationByHandle(handle, &info)) {
    errno = EBADF;
    return nullptr;
  }
  if (!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
    errno = ENOTDIR;
    return nullptr;
  }
  auto directory = std::make_unique<gufo_directory>();
  directory->fd = fd;
  directory->handle = handle;
  return directory.release();
}

extern "C" dirent* readdir(DIR* directory) {
  if (directory->finished)
    return nullptr;
  if (directory->refill) {
    if (!GetFileInformationByHandleEx(
            directory->handle,
            directory->first ? FileIdBothDirectoryRestartInfo
                             : FileIdBothDirectoryInfo,
            directory->buffer.data(),
            static_cast<DWORD>(directory->buffer.size() *
                               sizeof(unsigned long long)))) {
      if (GetLastError() != ERROR_NO_MORE_FILES)
        errno = EIO;
      directory->finished = true;
      return nullptr;
    }
    directory->first = false;
    directory->offset = 0;
  }
  const auto* item = reinterpret_cast<const FILE_ID_BOTH_DIR_INFO*>(
      reinterpret_cast<const unsigned char*>(directory->buffer.data()) +
      directory->offset);
  const auto count = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, item->FileName,
      static_cast<int>(item->FileNameLength / sizeof(wchar_t)),
      directory->entry.d_name, sizeof(directory->entry.d_name) - 1, nullptr,
      nullptr);
  if (!count) {
    errno = EILSEQ;
    return nullptr;
  }
  directory->entry.d_name[count] = '\0';
  directory->refill = item->NextEntryOffset == 0;
  directory->offset += item->NextEntryOffset;
  return &directory->entry;
}

extern "C" int closedir(DIR* directory) {
  const int result = close(directory->fd);
  delete directory;
  return result;
}
