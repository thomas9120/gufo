#include <fcntl.h>
#include <unistd.h>
#include <windows.h>

#include <algorithm>
#include <array>
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "compat/win32/filesystem.hpp"
#include "src/cache/disk.hpp"

using namespace gufo::cache;
namespace fs = std::filesystem;
namespace {
constexpr std::uint64_t kBudget = 100000;
ResourceLedger ledger{{1ULL << 26, 1ULL << 26, 0, 0}};
struct Directory {
  fs::path path;
  Directory() {
    auto name = (fs::temp_directory_path() / "gufo-disk-XXXXXX").string();
    assert(mkdtemp(name.data()));
    path = fs::path(name) / L"cache with spaces-\u00e9";
  }
  ~Directory() { fs::remove_all(path.parent_path()); }
};
DiskFileId Id(unsigned n) {
  DiskFileId id{};
  id[0] = n;
  return id;
}
struct Fixture {
  std::vector<std::uint8_t> chunk = std::vector<std::uint8_t>(8, 42);
  std::vector<std::uint8_t> tail = std::vector<std::uint8_t>(4, 17);
  std::vector<std::uint8_t> state = std::vector<std::uint8_t>(16, 9);
  DiskManifest manifest;
  std::vector<DiskWriteBuffer> buffers;
  explicit Fixture(unsigned n = 1) {
    manifest.checkpoint = {n};
    manifest.lineage = {1};
    manifest.tokens = {1, 2, 3};
    manifest.components = {{{{1}, 1, ComponentKind::kAppendRows, 4, 2, 0},
                            {{1}, 3},
                            {{Id(1), 8, DiskChecksum(chunk)}},
                            DiskPayload{Id(10 + n), 4, DiskChecksum(tail)},
                            {}},
                           {{{2}, 1, ComponentKind::kPrivateState, 0, 0, 16},
                            {{2}, 3},
                            {},
                            {},
                            DiskPayload{Id(20 + n), 16, DiskChecksum(state)}}};
    buffers = {{false, Id(1), chunk},
               {true, Id(10 + n), tail},
               {true, Id(20 + n), state}};
  }
};
template<class F>
void Reject(F action) {
  bool rejected{};
  try {
    action();
  } catch (const std::exception&) {
    rejected = true;
  }
  assert(rejected);
}
std::uint64_t Managed(const fs::path& root) {
  std::uint64_t bytes{};
  for (auto name : {"chunks", "private", "manifests", "tmp"})
    for (const auto& entry : fs::directory_iterator(root / "v2" / name))
      if (entry.path().extension() == ".bin")
        bytes += entry.file_size();
  return bytes;
}
void CheckPublished(DiskStore& store) {
  for (const auto& entry : store.Entries()) {
    assert(entry.Durable());
    auto snapshot = store.Open(entry.Manifest().checkpoint);
    assert(snapshot);
    for (const auto& component : snapshot->Manifest().components) {
      auto check = [&](bool private_file, const DiskPayload& payload) {
        std::array<std::uint8_t, 3> staging{};
        std::vector<std::uint8_t> bytes;
        const auto stats = store.ReadPayload(
            *snapshot, private_file, payload, staging,
            [&](auto offset, auto piece) {
              assert(offset == bytes.size());
              bytes.insert(bytes.end(), piece.begin(), piece.end());
            });
        assert(stats.bytes == payload.bytes &&
               DiskChecksum(bytes) == payload.checksum);
      };
      for (const auto& payload : component.chunks)
        check(false, payload);
      for (const auto& payload : {component.tail, component.private_state})
        if (payload)
          check(true, *payload);
    }
  }
}
DWORD Child(const fs::path& root, const std::wstring& arguments) {
  wchar_t executable[32768];
  assert(GetModuleFileNameW(nullptr, executable, 32768));
  auto command = L"\"" + std::wstring(executable) + L"\" --child \"" +
                 root.wstring() + L"\" " + arguments;
  STARTUPINFOW startup{sizeof(startup)};
  PROCESS_INFORMATION process{};
  assert(CreateProcessW(executable, command.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &startup,
                        &process));
  assert(WaitForSingleObject(process.hProcess, 10000) == WAIT_OBJECT_0);
  DWORD status{};
  assert(GetExitCodeProcess(process.hProcess, &status));
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return status;
}
int CrashChild(const fs::path& root, int step, int occurrence) {
  DiskStore store(ledger, root, kBudget);
  Fixture fixture;
  int count{};
  store.SetCrashHook([&](auto current) {
    if (int(current) == step && count++ == occurrence)
      TerminateProcess(GetCurrentProcess(), 73);
  });
  store.Publish(Id(100), fixture.manifest, fixture.buffers);
  return 0;
}
void Crashes() {
  for (int step = 0; step <= int(DiskPublicationStep::kIndexed); ++step) {
    for (int occurrence = 0; occurrence < 3; ++occurrence) {
      Directory directory;
      const auto status =
          Child(directory.path,
                std::to_wstring(step) + L" " + std::to_wstring(occurrence));
      const bool crashed =
          occurrence == 0 || step <= int(DiskPublicationStep::kPayloadRenamed);
      assert(status == (crashed ? 73 : 0));
      DiskStore reopened(ledger, directory.path, kBudget);
      const bool published =
          !crashed || step >= int(DiskPublicationStep::kManifestRenamed);
      assert(reopened.Entries().size() == (published ? 1 : 0));
      CheckPublished(reopened);
      assert(reopened.Stats().managed_bytes == Managed(directory.path));
      reopened.ReclaimOrphans();
      reopened.WaitForReclamation();
      CheckPublished(reopened);
      assert(reopened.Stats().managed_bytes == Managed(directory.path));
      assert(fs::is_empty(directory.path / "v2/tmp"));
      if (!published)
        assert(Managed(directory.path) == 0);
    }
  }
}
void SharingAndStreaming() {
  Directory directory;
  Fixture first, second(2);
  {
    DiskStore store(ledger, directory.path, kBudget);
    // A real subprocess must fail to acquire the same ownership lock.
    assert(Child(directory.path, L"lock") == 0);
    store.Publish(Id(100), first.manifest, first.buffers);
    auto pin = store.Pin({1});
    assert(pin && !store.Retire({1}));
    std::vector<DiskWriteSource> sources;
    for (const auto& buffer : second.buffers) {
      if (!buffer.private_file)
        continue;
      sources.push_back({true, buffer.file, buffer.bytes.size(),
                         [bytes = buffer.bytes](auto offset, auto piece) {
                           std::copy_n(bytes.begin() + offset, piece.size(),
                                       piece.begin());
                         }});
    }
    std::array<std::uint8_t, 3> staging{};
    const auto stats =
        store.PublishStream(Id(101), second.manifest, sources, staging);
    assert(stats.fsync_calls > 0);
    CheckPublished(store);
    pin = {};
    assert(store.Retire({1}));
    assert(fs::exists(directory.path / "v2/chunks" / DiskFileName(Id(1))));
  }
  DiskStore reopened(ledger, directory.path, kBudget);
  assert(reopened.Entries().size() == 1);
  CheckPublished(reopened);
  assert(reopened.Retire({2}));
  assert(Managed(directory.path) == 0);
}
void Corruption() {
  for (auto kind :
       {"manifest", "missing", "truncated", "checksum", "hardlink", "public"}) {
    Directory directory;
    Fixture fixture;
    {
      DiskStore store(ledger, directory.path, kBudget);
      store.Publish(Id(100), fixture.manifest, fixture.buffers);
    }
    const auto dependency = directory.path / "v2/chunks" / DiskFileName(Id(1));
    if (std::string(kind) == "missing")
      fs::remove(dependency);
    else if (std::string(kind) == "truncated")
      fs::resize_file(dependency, 2);
    else if (std::string(kind) == "hardlink")
      fs::create_hard_link(dependency, directory.path / "extra-link");
    else if (std::string(kind) == "public") {
      // Replace the private file with one inheriting the ordinary temp ACL.
      const auto public_file = directory.path.parent_path() / "public";
      std::ofstream(public_file, std::ios::binary) << "12345678";
      fs::remove(dependency);
      fs::rename(public_file, dependency);
    } else {
      const auto path =
          std::string(kind) == "manifest"
              ? directory.path / "v2/manifests" / DiskFileName(Id(100))
              : dependency;
      std::fstream file(path, std::ios::in | std::ios::out | std::ios::binary);
      file.put('\xff');
      assert(file.good());
    }
    DiskStore reopened(ledger, directory.path, kBudget);
    if (std::string(kind) == "checksum") {
      assert(reopened.Entries().size() == 1);
      // Startup deliberately avoids payload reads. Restore must reject it.
      Reject([&] { CheckPublished(reopened); });
      assert(!reopened.Open({1}));
      assert(reopened.Retire({1}));
    } else {
      assert(reopened.Entries().empty());
      assert(reopened.Stats().rejected_manifests == 1);
    }
    reopened.ReclaimOrphans();
    reopened.WaitForReclamation();
    assert(fs::is_empty(directory.path / "v2/manifests"));
  }
}
void PublicationFailures() {
  for (const auto* operation : {"write", "sync", "rename"}) {
    const int count = std::string(operation) == "sync" ? 9 : 4;
    for (int occurrence = 0; occurrence < count; ++occurrence) {
      for (bool after : {false, true}) {
        if (after && std::string(operation) != "rename")
          continue;
        Directory directory;
        Fixture fixture;
        {
          DiskStore store(ledger, directory.path, kBudget);
          gufo::win32::SetFault(operation, occurrence, after);
          Reject([&] {
            store.Publish(Id(100), fixture.manifest, fixture.buffers);
          });
          gufo::win32::SetFault(operation, -1);
          store.ReclaimOrphans();
          store.WaitForReclamation();
          assert(store.Stats().managed_bytes == Managed(directory.path));
          CheckPublished(store);
        }
        DiskStore reopened(ledger, directory.path, kBudget);
        CheckPublished(reopened);
      }
    }
  }
  for (const auto* operation : {"unlink", "sync"}) {
    for (bool after : {false, true}) {
      if (after && std::string(operation) != "unlink")
        continue;
      Directory directory;
      Fixture fixture;
      {
        DiskStore store(ledger, directory.path, kBudget);
        store.Publish(Id(100), fixture.manifest, fixture.buffers);
        gufo::win32::SetFault(operation, 0, after);
        Reject([&] { (void)store.Retire({1}); });
        gufo::win32::SetFault(operation, -1);
        store.ReclaimOrphans();
        store.WaitForReclamation();
        assert(store.Stats().managed_bytes == Managed(directory.path));
        CheckPublished(store);
      }
      DiskStore reopened(ledger, directory.path, kBudget);
      CheckPublished(reopened);
    }
  }
}
void Privacy() {
  Directory directory;
  fs::create_directories(directory.path);
  Reject([&] { DiskStore store(ledger, directory.path, kBudget); });
  assert(!fs::exists(directory.path / "LOCK"));
  fs::remove(directory.path);
  assert(mkdir(directory.path.c_str(), 0700) == 0);
  fs::create_directory(directory.path / "v2");
  Reject([&] { DiskStore store(ledger, directory.path, kBudget); });
  fs::remove(directory.path / "v2");
  fs::remove(directory.path / "LOCK");
  {
    // An existing unprotected ownership file must not be trusted either.
    std::ofstream lock(directory.path / "LOCK");
  }
  Reject([&] { DiskStore store(ledger, directory.path, kBudget); });
  fs::remove(directory.path / "LOCK");
  DiskStore store(ledger, directory.path, kBudget);
  assert(store.Entries().empty());
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc >= 4 && std::wstring(argv[1]) == L"--child") {
    if (std::wstring(argv[3]) == L"lock") {
      Reject([&] { DiskStore store(ledger, argv[2], kBudget); });
      return 0;
    }
    assert(argc == 5);
    return CrashChild(argv[2], std::stoi(argv[3]), std::stoi(argv[4]));
  }
  std::cout << "Windows cache: publication crash boundaries\n" << std::flush;
  Crashes();
  std::cout << "Windows cache: ownership, sharing and streaming\n"
            << std::flush;
  SharingAndStreaming();
  std::cout << "Windows cache: corruption and incomplete checkpoints\n"
            << std::flush;
  Corruption();
  std::cout << "Windows cache: root, layout and lock privacy\n" << std::flush;
  Privacy();
  std::cout << "Windows cache: publication and retirement I/O failures\n"
            << std::flush;
  PublicationFailures();
  std::cout << "Windows disk store checks passed\n";
}
