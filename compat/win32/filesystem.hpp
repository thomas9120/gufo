#ifndef GUFO_WIN32_FILESYSTEM_HPP_
#define GUFO_WIN32_FILESYSTEM_HPP_

#include <windows.h>

#include <string>

namespace gufo::win32 {
// Native file operations preserve directory-handle identity across renames.
HANDLE OpenAt(HANDLE parent, const std::wstring& path, DWORD access,
              DWORD disposition, DWORD options, unsigned mode, bool no_follow);
// Private local NTFS cache root; traverses ancestors without write access.
// Rejects reparse points, parent components and non-private existing roots.
HANDLE OpenCacheDirectory(const std::wstring& path);
int RenameAt(HANDLE parent, const std::wstring& source, HANDLE destination,
             const std::wstring& name, bool replace);
int UnlinkAt(HANDLE parent, const std::wstring& name, bool directory);
unsigned Permissions(HANDLE file, bool directory, unsigned* owner);
int Chmod(HANDLE file, unsigned mode);
#ifdef GUFO_WIN32_TESTING
bool Fault(const char* operation, bool after = false);
// Configure only while the fixture has no pending I/O.
void SetFault(const char* operation, int occurrence, bool after = false);
#else
inline bool Fault(const char*, bool = false) {
  return false;
}
#endif
}  // namespace gufo::win32

#endif
