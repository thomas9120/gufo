#include "filesystem.hpp"

#include <aclapi.h>
#include <winternl.h>

#include <atomic>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <optional>
#include <vector>

namespace gufo::win32 {
namespace {

struct Identity {
  std::vector<unsigned char> user;
  Identity() {
    HANDLE token{};
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
      return;
    DWORD bytes = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &bytes);
    user.resize(bytes);
    if (!GetTokenInformation(token, TokenUser, user.data(), bytes, &bytes))
      user.clear();
    CloseHandle(token);
  }
  PSID Sid() const {
    return user.empty()
               ? nullptr
               : reinterpret_cast<const TOKEN_USER*>(user.data())->User.Sid;
  }
};
PSID UserSid() {
  static const Identity identity;
  return identity.Sid();
}

struct PrivateSecurity {
  SECURITY_DESCRIPTOR descriptor{};
  std::vector<unsigned char> storage;
  bool valid{};
  explicit PrivateSecurity(bool directory) {
    const auto sid = UserSid();
    if (!sid)
      return;
    storage.resize(sizeof(ACL) + sizeof(ACCESS_ALLOWED_ACE) +
                   GetLengthSid(sid));
    auto* acl = reinterpret_cast<PACL>(storage.data());
    valid =
        InitializeAcl(acl, static_cast<DWORD>(storage.size()), ACL_REVISION) &&
        AddAccessAllowedAceEx(
            acl, ACL_REVISION,
            directory ? OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE : 0,
            FILE_ALL_ACCESS, sid) &&
        InitializeSecurityDescriptor(&descriptor,
                                     SECURITY_DESCRIPTOR_REVISION) &&
        SetSecurityDescriptorOwner(&descriptor, sid, FALSE) &&
        SetSecurityDescriptorDacl(&descriptor, TRUE, acl, FALSE) &&
        SetSecurityDescriptorControl(&descriptor, SE_DACL_PROTECTED,
                                     SE_DACL_PROTECTED);
  }
};

int NtError(NTSTATUS status) {
  using Function = ULONG(WINAPI*)(NTSTATUS);
  static const auto convert = reinterpret_cast<Function>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlNtStatusToDosError"));
  const auto error = convert ? convert(status) : ERROR_NOT_SUPPORTED;
  SetLastError(error);
  return -1;
}

std::wstring NativeName(const std::wstring& path) {
  std::vector<wchar_t> full(32768);
  const auto count = GetFullPathNameW(
      path.c_str(), static_cast<DWORD>(full.size()), full.data(), nullptr);
  if (!count || count >= full.size()) {
    SetLastError(ERROR_BAD_PATHNAME);
    return {};
  }
  std::wstring name(full.data(), count);
  if (name.starts_with(L"\\\\?\\"))
    return L"\\??\\" + name.substr(4);
  if (name.starts_with(L"\\\\"))
    return L"\\??\\UNC\\" + name.substr(2);
  return L"\\??\\" + name;
}

#ifdef GUFO_WIN32_TESTING
std::atomic<int> remaining{-1};
std::string fault_operation;
bool fault_after{};
#endif
}  // namespace

HANDLE OpenAt(HANDLE parent, const std::wstring& path, DWORD access,
              DWORD disposition, DWORD options, unsigned mode, bool no_follow) {
  if (path.empty()) {
    SetLastError(ERROR_PATH_NOT_FOUND);
    return INVALID_HANDLE_VALUE;
  }
  using Function = decltype(&NtCreateFile);
  static const auto create = reinterpret_cast<Function>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtCreateFile"));
  std::wstring name = path;
  if (name.size() >= 2 && (name[1] == L':' || name[0] == L'\\'))
    parent = nullptr;
  if (!parent) {
    name = NativeName(path);
    if (name.empty())
      return INVALID_HANDLE_VALUE;
  } else if (name == L".") {
    name.clear();
  }
  if (!create || name.size() * sizeof(wchar_t) > 65534) {
    SetLastError(ERROR_NOT_SUPPORTED);
    return INVALID_HANDLE_VALUE;
  }
  UNICODE_STRING unicode{};
  unicode.Buffer = name.data();
  unicode.Length = unicode.MaximumLength =
      static_cast<USHORT>(name.size() * sizeof(wchar_t));
  OBJECT_ATTRIBUTES attributes{};
  attributes.Length = sizeof(attributes);
  attributes.RootDirectory = parent;
  attributes.ObjectName = &unicode;
  // OBJ_DONT_REPARSE rejects intermediate reparse points as well as the leaf.
  attributes.Attributes = 0x40 /* OBJ_CASE_INSENSITIVE */ |
                          (no_follow ? 0x1000 /* OBJ_DONT_REPARSE */ : 0);
  std::optional<PrivateSecurity> security;
  if (disposition != 1 /* FILE_OPEN */ && mode && !(mode & 0077)) {
    security.emplace((options & 1 /* FILE_DIRECTORY_FILE */) != 0);
    if (!security->valid) {
      SetLastError(ERROR_ACCESS_DENIED);
      return INVALID_HANDLE_VALUE;
    }
    attributes.SecurityDescriptor = &security->descriptor;
  }
  HANDLE file{};
  IO_STATUS_BLOCK result{};
  const auto file_attributes = mode && !(mode & 0200) && !(options & 1)
                                   ? FILE_ATTRIBUTE_READONLY
                                   : FILE_ATTRIBUTE_NORMAL;
  auto status = create(&file, access | SYNCHRONIZE, &attributes, &result,
                       nullptr, file_attributes,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       disposition, options, nullptr, 0);
  if (status == 0x103 /* STATUS_PENDING */) {
    if (WaitForSingleObject(file, INFINITE) != WAIT_OBJECT_0) {
      const auto error = GetLastError();
      CloseHandle(file);
      SetLastError(error);
      return INVALID_HANDLE_VALUE;
    }
    status = result.Status;
  }
  if (status < 0) {
    if (file)
      CloseHandle(file);
    NtError(status);
    return INVALID_HANDLE_VALUE;
  }
  return file;
}

unsigned Permissions(HANDLE file, bool directory, unsigned* owner) {
  *owner = 1;  // Synthetic POSIX uid 0 denotes this process's real token SID.
  PSID sid{};
  PACL acl{};
  PSECURITY_DESCRIPTOR descriptor{};
  const auto error =
      GetSecurityInfo(file, SE_FILE_OBJECT,
                      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                      &sid, nullptr, &acl, nullptr, &descriptor);
  if (error != ERROR_SUCCESS)
    return 0777;  // Unknown privacy must fail closed in cache checks.
  const auto user = UserSid();
  if (user && sid && EqualSid(user, sid))
    *owner = 0;
  SECURITY_DESCRIPTOR_CONTROL control{};
  DWORD revision{};
  bool private_acl =
      *owner == 0 && acl &&
      GetSecurityDescriptorControl(descriptor, &control, &revision) &&
      (control & SE_DACL_PROTECTED);
  bool full_access = false;
  if (private_acl) {
    for (DWORD i = 0; i < acl->AceCount; ++i) {
      void* raw{};
      if (!GetAce(acl, i, &raw)) {
        private_acl = false;
        break;
      }
      const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw);
      if (ace->Header.AceType != ACCESS_ALLOWED_ACE_TYPE ||
          !EqualSid(user, const_cast<DWORD*>(&ace->SidStart)) ||
          (ace->Header.AceFlags & INHERIT_ONLY_ACE)) {
        private_acl = false;
        break;
      }
      full_access |= (ace->Mask & FILE_ALL_ACCESS) == FILE_ALL_ACCESS;
    }
  }
  LocalFree(descriptor);
  return private_acl && full_access ? (directory ? 0700 : 0600) : 0777;
}

HANDLE OpenCacheDirectory(const std::wstring& path) {
  // absolute() uses Win32 normalization, which would erase '..' before the
  // no-follow traversal can check the preceding component.
  for (const auto& part : std::filesystem::path(path))
    if (part == L"..") {
      SetLastError(ERROR_BAD_PATHNAME);
      return INVALID_HANDLE_VALUE;
    }
  const auto absolute = std::filesystem::absolute(path);
  std::vector<std::wstring> components;
  for (const auto& part : absolute.relative_path()) {
    if (part != L".")
      components.push_back(part.wstring());
  }
  if (components.empty()) {
    SetLastError(ERROR_ACCESS_DENIED);
    return INVALID_HANDLE_VALUE;
  }
  const auto drive = GetDriveTypeW(absolute.root_path().c_str());
  if (drive != DRIVE_FIXED && drive != DRIVE_REMOVABLE) {
    SetLastError(ERROR_NOT_SUPPORTED);
    return INVALID_HANDLE_VALUE;
  }
  constexpr DWORD traverse =
      FILE_TRAVERSE | FILE_READ_ATTRIBUTES | READ_CONTROL;
  constexpr DWORD options = 1 | 0x20 | 0x200000;
  auto directory = OpenAt(nullptr, absolute.root_path().wstring(), traverse, 1,
                          options, 0, true);
  if (directory == INVALID_HANDLE_VALUE)
    return directory;
  for (std::size_t i = 0; i < components.size(); ++i) {
    const bool last = i + 1 == components.size();
    const auto access = last ? GENERIC_READ | GENERIC_WRITE : traverse;
    auto child = OpenAt(directory, components[i], access, 1, options, 0, true);
    if (child == INVALID_HANDLE_VALUE &&
        (GetLastError() == ERROR_FILE_NOT_FOUND ||
         GetLastError() == ERROR_PATH_NOT_FOUND))
      child = OpenAt(directory, components[i], access, 3, options, 0700, true);
    const auto error = GetLastError();
    CloseHandle(directory);
    if (child == INVALID_HANDLE_VALUE) {
      SetLastError(error);
      return child;
    }
    FILE_ATTRIBUTE_TAG_INFO tag{};
    if (!GetFileInformationByHandleEx(child, FileAttributeTagInfo, &tag,
                                      sizeof(tag))) {
      const auto query_error = GetLastError();
      CloseHandle(child);
      SetLastError(query_error);
      return INVALID_HANDLE_VALUE;
    }
    if (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
      CloseHandle(child);
      SetLastError(ERROR_REPARSE_POINT_ENCOUNTERED);
      return INVALID_HANDLE_VALUE;
    }
    directory = child;
  }
  unsigned owner{};
  wchar_t filesystem[32]{};
  DWORD flags{};
  // SMB does not support this volume query. Only local NTFS is qualified.
  if (Permissions(directory, true, &owner) != 0700 || owner != 0) {
    CloseHandle(directory);
    SetLastError(ERROR_ACCESS_DENIED);
    return INVALID_HANDLE_VALUE;
  }
  if (!GetVolumeInformationByHandleW(directory, nullptr, 0, nullptr, nullptr,
                                     &flags, filesystem, 32) ||
      std::wstring(filesystem) != L"NTFS" || !(flags & FILE_PERSISTENT_ACLS)) {
    CloseHandle(directory);
    SetLastError(ERROR_NOT_SUPPORTED);
    return INVALID_HANDLE_VALUE;
  }
  return directory;
}

int Chmod(HANDLE file, unsigned mode) {
  if (mode != 0600 && mode != 0700) {
    errno = ENOTSUP;
    return -1;
  }
  unsigned owner{};
  (void)Permissions(file, false, &owner);
  if (owner != 0) {
    errno = EACCES;
    return -1;
  }
  FILE_ATTRIBUTE_TAG_INFO info{};
  if (!GetFileInformationByHandleEx(file, FileAttributeTagInfo, &info,
                                    sizeof(info)) ||
      (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    errno = ELOOP;
    return -1;
  }
  PrivateSecurity security((info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) !=
                           0);
  if (!security.valid) {
    errno = EACCES;
    return -1;
  }
  if (info.FileAttributes & FILE_ATTRIBUTE_READONLY) {
    FILE_BASIC_INFO basic{};
    basic.FileAttributes = info.FileAttributes & ~FILE_ATTRIBUTE_READONLY;
    if (!basic.FileAttributes)
      basic.FileAttributes = FILE_ATTRIBUTE_NORMAL;
    if (!SetFileInformationByHandle(file, FileBasicInfo, &basic,
                                    sizeof(basic))) {
      errno = EACCES;
      return -1;
    }
  }
  const auto error = SetSecurityInfo(
      file, SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr,
      nullptr, reinterpret_cast<PACL>(security.storage.data()), nullptr);
  if (error != ERROR_SUCCESS) {
    errno = EACCES;
    return -1;
  }
  return 0;
}

int RenameAt(HANDLE parent, const std::wstring& source, HANDLE destination,
             const std::wstring& name, bool replace) {
  const auto file =
      OpenAt(parent, source, DELETE, 1, 0x20 /* synchronous */, 0, true);
  if (file == INVALID_HANDLE_VALUE)
    return -1;
  auto target = name;
  if (name.size() >= 2 && (name[1] == L':' || name[0] == L'\\'))
    destination = nullptr;
  if (!destination)
    target = NativeName(name);
  if (target.empty()) {
    CloseHandle(file);
    return -1;
  }
  const auto size = sizeof(FILE_RENAME_INFO) + target.size() * sizeof(wchar_t);
  std::vector<unsigned char> storage(size);
  auto* info = reinterpret_cast<FILE_RENAME_INFO*>(storage.data());
  info->Flags = replace ? 3 /* REPLACE_IF_EXISTS | POSIX_SEMANTICS */ : 0;
  info->RootDirectory = destination;
  info->FileNameLength = static_cast<DWORD>(target.size() * sizeof(wchar_t));
  std::memcpy(info->FileName, target.data(), info->FileNameLength);
  using Function = NTSTATUS(NTAPI*)(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG,
                                    FILE_INFORMATION_CLASS);
  static const auto rename = reinterpret_cast<Function>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtSetInformationFile"));
  IO_STATUS_BLOCK result{};
  const auto status =
      rename ? rename(file, &result, info, static_cast<ULONG>(size),
                      static_cast<FILE_INFORMATION_CLASS>(
                          65 /* FileRenameInformationEx */))
             : static_cast<NTSTATUS>(0xc0000002);
  CloseHandle(file);
  return status >= 0 ? 0 : NtError(status);
}

int UnlinkAt(HANDLE parent, const std::wstring& name, bool directory) {
  const auto file =
      OpenAt(parent, name, DELETE | FILE_READ_ATTRIBUTES, 1,
             0x20 | 0x200000 /* synchronous + reparse leaf */, 0, false);
  if (file == INVALID_HANDLE_VALUE)
    return -1;
  FILE_ATTRIBUTE_TAG_INFO info{};
  const auto queried = GetFileInformationByHandleEx(file, FileAttributeTagInfo,
                                                    &info, sizeof(info));
  if (!queried ||
      bool(info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != directory) {
    CloseHandle(file);
    SetLastError(directory ? ERROR_DIRECTORY : ERROR_ACCESS_DENIED);
    return -1;
  }
  FILE_DISPOSITION_INFO_EX disposition{
      FILE_DISPOSITION_FLAG_DELETE | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS |
      FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE};
  const auto ok = SetFileInformationByHandle(file, FileDispositionInfoEx,
                                             &disposition, sizeof(disposition));
  const auto error = GetLastError();
  CloseHandle(file);
  SetLastError(error);
  return ok ? 0 : -1;
}

#ifdef GUFO_WIN32_TESTING
bool Fault(const char* operation, bool after) {
  if (remaining.load() >= 0 && fault_operation == operation &&
      fault_after == after && remaining.fetch_sub(1) == 0) {
    errno = EIO;
    return true;
  }
  return false;
}

void SetFault(const char* operation, int occurrence, bool after) {
  remaining = -1;
  fault_operation = operation;
  fault_after = after;
  remaining = occurrence;
}
#endif
}  // namespace gufo::win32
