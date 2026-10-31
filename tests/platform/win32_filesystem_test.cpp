#include <aclapi.h>
#include <dirent.h>
#include <fcntl.h>
#include <io.h>
#include <sddl.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <windows.h>
#include <winioctl.h>

#include <cassert>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "compat/win32/filesystem.hpp"

namespace fs = std::filesystem;

namespace {
struct Directory {
  fs::path path;
  Directory() {
    auto name = (fs::temp_directory_path() / "gufo-private-XXXXXX").string();
    assert(mkdtemp(name.data()));
    path = name;
  }
  ~Directory() { fs::remove_all(path); }
};

void CheckPrivate(const fs::path& path, bool directory) {
  const auto file =
      CreateFileW(path.c_str(), READ_CONTROL, 7, nullptr, OPEN_EXISTING,
                  FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  assert(file != INVALID_HANDLE_VALUE);
  PSID owner{};
  PACL acl{};
  PSECURITY_DESCRIPTOR descriptor{};
  assert(GetSecurityInfo(file, SE_FILE_OBJECT,
                         OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                         &owner, nullptr, &acl, nullptr,
                         &descriptor) == ERROR_SUCCESS);
  SECURITY_DESCRIPTOR_CONTROL control{};
  DWORD revision{};
  assert(GetSecurityDescriptorControl(descriptor, &control, &revision));
  assert((control & SE_DACL_PROTECTED) && acl && acl->AceCount == 1);
  void* raw{};
  assert(GetAce(acl, 0, &raw));
  const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw);
  assert(ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE);
  assert(EqualSid(owner, const_cast<DWORD*>(&ace->SidStart)));
  assert((ace->Mask & FILE_ALL_ACCESS) == FILE_ALL_ACCESS);
  LocalFree(descriptor);
  CloseHandle(file);
  struct stat status{};
  assert(stat(path.c_str(), &status) == 0 && status.st_uid == geteuid());
  assert((status.st_mode & 0777) == (directory ? 0700 : 0600));
}

void MakePublic(const fs::path& path) {
  PSECURITY_DESCRIPTOR descriptor{};
  assert(ConvertStringSecurityDescriptorToSecurityDescriptorW(
      L"D:P(A;;FA;;;WD)", SDDL_REVISION_1, &descriptor, nullptr));
  assert(SetFileSecurityW(path.c_str(), DACL_SECURITY_INFORMATION, descriptor));
  LocalFree(descriptor);
}

void Junction(const fs::path& link, const fs::path& target) {
  assert(CreateDirectoryW(link.c_str(), nullptr));
  const auto handle = CreateFileW(
      link.c_str(), GENERIC_WRITE, 7, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  assert(handle != INVALID_HANDLE_VALUE);
  const auto print = fs::absolute(target).wstring();
  const auto substitute = L"\\??\\" + print;
  struct Header {
    DWORD tag;
    WORD bytes, reserved, substitute_offset, substitute_length, print_offset,
        print_length;
  };
  const auto first = substitute.size() * sizeof(wchar_t);
  const auto second = print.size() * sizeof(wchar_t);
  std::vector<unsigned char> storage(sizeof(Header) + first + second + 4);
  auto* header = reinterpret_cast<Header*>(storage.data());
  header->tag = IO_REPARSE_TAG_MOUNT_POINT;
  header->bytes = static_cast<WORD>(8 + first + second + 4);
  header->substitute_length = static_cast<WORD>(first);
  header->print_offset = static_cast<WORD>(first + 2);
  header->print_length = static_cast<WORD>(second);
  auto* names = storage.data() + sizeof(Header);
  std::memcpy(names, substitute.data(), first);
  std::memcpy(names + first + 2, print.data(), second);
  DWORD returned{};
  assert(DeviceIoControl(handle, FSCTL_SET_REPARSE_POINT, storage.data(),
                         static_cast<DWORD>(storage.size()), nullptr, 0,
                         &returned, nullptr));
  CloseHandle(handle);
}

void TestPrivacy() {
  Directory directory;
  CheckPrivate(directory.path, true);
  const auto path = directory.path / "private";
  const int file =
      open(path.c_str(), O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
  assert(file >= 0 && write(file, "secret", 6) == 6);
  assert(fsync(file) == 0);
  assert(close(file) == 0);
  CheckPrivate(path, false);

  // A restricted token must pass both its normal SID and a restricting SID.
  // The private DACL grants no access to the Everyone restricting SID.
  HANDLE token{}, restricted{};
  assert(OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY,
                          &token));
  unsigned char sid[SECURITY_MAX_SID_SIZE];
  DWORD bytes = sizeof(sid);
  assert(CreateWellKnownSid(WinWorldSid, nullptr, sid, &bytes));
  SID_AND_ATTRIBUTES restriction{sid, 0};
  assert(CreateRestrictedToken(token, 0, 0, nullptr, 0, nullptr, 1,
                               &restriction, &restricted));
  assert(ImpersonateLoggedOnUser(restricted));
  const auto denied = CreateFileW(path.c_str(), GENERIC_READ, 7, nullptr,
                                  OPEN_EXISTING, 0, nullptr);
  const auto error = GetLastError();
  assert(RevertToSelf());
  assert(denied == INVALID_HANDLE_VALUE && error == ERROR_ACCESS_DENIED);
  CloseHandle(restricted);
  CloseHandle(token);

  MakePublic(path);
  struct stat status{};
  assert(stat(path.c_str(), &status) == 0 && (status.st_mode & 0077));
  assert(chmod(path.c_str(), 0600) == 0);
  CheckPrivate(path, false);
  assert(chmod(path.c_str(), 0644) < 0 && errno == ENOTSUP);
  const int reopen = open(path.c_str(), O_RDWR);
  assert(reopen >= 0 && fchmod(reopen, 0600) == 0);
  assert(close(reopen) == 0);
  const auto readonly = directory.path / "readonly";
  const int read_only =
      open(readonly.c_str(), O_RDONLY | O_CREAT | O_EXCL, 0400);
  assert(read_only >= 0 && close(read_only) == 0);
  assert(open(readonly.c_str(), O_RDWR) < 0 && errno == EACCES);
  assert(chmod(readonly.c_str(), 0600) == 0);
  const int writable = open(readonly.c_str(), O_RDWR);
  assert(writable >= 0 && close(writable) == 0);
  const int parent = open(directory.path.c_str(), O_RDONLY | O_DIRECTORY);
  assert(parent >= 0 && unlinkat(parent, "readonly", 0) == 0);
  assert(!fs::exists(readonly) && close(parent) == 0);
}

void TestHandleIdentity() {
  Directory directory;
  const auto anchor = directory.path / "anchor";
  const auto moved = directory.path / "moved";
  assert(mkdir(anchor.c_str(), 0700) == 0);
  const int parent = open(anchor.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  assert(parent >= 0);
  assert(openat(parent, "", O_RDONLY) < 0 && errno == ENOENT);
  fs::rename(anchor, moved);
  fs::create_directory(anchor);
  const int original =
      openat(parent, "source", O_RDWR | O_CREAT | O_EXCL, 0600);
  assert(original >= 0 && write(original, "original", 8) == 8);
  assert(close(original) == 0);
  assert(fs::exists(moved / "source") && !fs::exists(anchor / "source"));
  assert(gufo_rename_noreplace(parent, "source", parent, "target") == 0);
  struct stat status{};
  assert(fstatat(parent, "target", &status, AT_SYMLINK_NOFOLLOW) == 0);
  assert(status.st_size == 8 && status.st_uid == geteuid());
  const int old = openat(parent, "target", O_RDONLY | O_NOFOLLOW);
  assert(old >= 0);
  const int newer = openat(parent, "source", O_RDWR | O_CREAT | O_EXCL, 0600);
  assert(newer >= 0 && write(newer, "new", 3) == 3 && close(newer) == 0);
  assert(gufo_rename_noreplace(parent, "source", parent, "target") < 0 &&
         errno == EEXIST);
  assert(renameat(parent, "source", parent, "target") == 0);
  char bytes[8];
  assert(read(old, bytes, sizeof(bytes)) == 8 &&
         std::string(bytes, 8) == "original");
  assert(close(old) == 0);
  assert(fstatat(parent, "target", &status, 0) == 0 && status.st_size == 3);
  const int copy = openat(parent, ".", O_RDONLY | O_DIRECTORY);
  assert(copy >= 0);
  DIR* scan = fdopendir(copy);
  assert(scan);
  bool found{};
  errno = 0;
  while (const auto* entry = readdir(scan))
    found |= std::string(entry->d_name) == "target";
  assert(found && errno == 0);
  assert(closedir(scan) == 0);
  assert(unlinkat(parent, "target", 0) == 0);
  assert(!fs::exists(moved / "target"));
  gufo::win32::SetFault("sync", 0);
  assert(fsync(parent) < 0 && errno == EIO);
  gufo::win32::SetFault("sync", -1);
  assert(fsync(parent) == 0);
  assert(close(parent) == 0);
  const auto source = directory.path / "absolute source";
  const auto target = directory.path / "absolute target";
  const int absolute = open(source.c_str(), O_RDWR | O_CREAT | O_EXCL, 0600);
  assert(absolute >= 0 && close(absolute) == 0);
  assert(renameat(AT_FDCWD, source.string().c_str(), AT_FDCWD,
                  target.string().c_str()) == 0);
  assert(fs::exists(target) && !fs::exists(source));
}

int CrashChild(const char* path, int phase) {
  const int root = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  assert(root >= 0);
  const int file =
      openat(root, "temporary", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
  assert(file >= 0);
  assert(write(file, "complete private payload", 24) == 24);
  auto crash = [] {
    TerminateProcess(GetCurrentProcess(), 42);
    std::abort();
  };
  if (phase == 0)
    crash();
  assert(fsync(file) == 0);
  if (phase == 1)
    crash();
  assert(gufo_rename_noreplace(root, "temporary", root, "published") == 0);
  if (phase == 2)
    crash();
  assert(fsync(root) == 0);
  crash();
  return 0;
}

void TestProcessDeath(const char* executable) {
  for (int phase = 0; phase != 4; ++phase) {
    Directory directory;
    auto program = std::string(executable);
    auto path = directory.path.string();
    auto step = std::to_string(phase);
    char mode[] = "--crash-child";
    char* arguments[]{program.data(), mode, path.data(), step.data(), nullptr};
    pid_t child{};
    assert(posix_spawn(&child, executable, nullptr, nullptr, arguments,
                       nullptr) == 0);
    int status{};
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 42);
    // Reopen through a new process description after forced termination.
    const int root =
        open(directory.path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    assert(root >= 0);
    if (phase < 2) {
      assert(!fs::exists(directory.path / "published"));
      assert(fs::exists(directory.path / "temporary"));
    } else {
      assert(!fs::exists(directory.path / "temporary"));
      std::ifstream file(directory.path / "published", std::ios::binary);
      const std::string contents((std::istreambuf_iterator<char>(file)), {});
      assert(contents == "complete private payload");
      CheckPrivate(directory.path / "published", false);
    }
    assert(close(root) == 0);
  }
}

void TestPublicationErrors() {
  Directory directory;
  const int root =
      open(directory.path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  assert(root >= 0);
  int file = openat(root, "temporary", O_RDWR | O_CREAT | O_EXCL, 0600);
  assert(file >= 0);
  gufo::win32::SetFault("write", 0);
  assert(write(file, "data", 4) < 0 && errno == EIO);
  gufo::win32::SetFault("write", -1);
  assert(write(file, "data", 4) == 4 && fsync(file) == 0);
  assert(close(file) == 0);
  gufo::win32::SetFault("rename", 0);
  assert(gufo_rename_noreplace(root, "temporary", root, "published") < 0 &&
         errno == EIO);
  assert(fs::exists(directory.path / "temporary") &&
         !fs::exists(directory.path / "published"));
  gufo::win32::SetFault("rename", 0, true);
  assert(gufo_rename_noreplace(root, "temporary", root, "published") < 0 &&
         errno == EIO);
  assert(!fs::exists(directory.path / "temporary") &&
         fs::exists(directory.path / "published"));
  gufo::win32::SetFault("unlink", 0);
  assert(unlinkat(root, "published", 0) < 0 && errno == EIO);
  assert(fs::exists(directory.path / "published"));
  gufo::win32::SetFault("unlink", 0, true);
  assert(unlinkat(root, "published", 0) < 0 && errno == EIO);
  assert(!fs::exists(directory.path / "published"));
  gufo::win32::SetFault("unlink", -1);
  assert(close(root) == 0);
}

void TestReparsePoints() {
  Directory directory;
  const auto link = directory.path / "junction";
  const auto target = directory.path / "target";
  assert(mkdir(target.c_str(), 0700) == 0);
  Junction(link, target);
  assert(open(link.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW) < 0 &&
         errno == ELOOP);
  assert(open((link / "outside").c_str(),
              O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) < 0 &&
         errno == ELOOP);
  assert(!fs::exists(target / "outside"));
  // Cache creation must preserve no-follow traversal through every ancestor.
  assert(gufo_open_cache_directory(link.c_str()) < 0 && errno == ELOOP);
  assert(gufo_open_cache_directory((link / "outside").c_str()) < 0 &&
         errno == ELOOP);
  assert(!fs::exists(target / "outside"));
  assert(RemoveDirectoryW(link.c_str()));
}

void TestCacheDirectory() {
  Directory directory;
  const auto path = directory.path / L"nested/cache-\u00e9";
  const int root = gufo_open_cache_directory(path.c_str());
  assert(root >= 0);
  CheckPrivate(path, true);
  CheckPrivate(path.parent_path(), true);
  assert(fsync(root) == 0 && close(root) == 0);
  const int reopened = gufo_open_cache_directory(path.c_str());
  assert(reopened >= 0 && close(reopened) == 0);
  assert(gufo_open_cache_directory((path / ".." / "outside").c_str()) < 0);
  assert(!fs::exists(path.parent_path() / "outside"));
  MakePublic(path);
  assert(gufo_open_cache_directory(path.c_str()) < 0 && errno == EACCES);
}
}  // namespace

int main(int argc, char** argv) {
  if (argc == 4 && std::string(argv[1]) == "--crash-child")
    return CrashChild(argv[2], std::stoi(argv[3]));
  TestPrivacy();
  TestHandleIdentity();
  TestReparsePoints();
  TestCacheDirectory();
  TestProcessDeath(argv[0]);
  TestPublicationErrors();
  std::cout << "Windows filesystem guarantees passed\n";
}
