#include <unistd.h>
#include <windows.h>

#include <algorithm>
#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>

#include "src/cli/diagnose/diagnose.h"
#include "src/cli/serve/logging.hpp"
#include "src/cli/serve/text_model_runner.hpp"
#include "src/core/diagnostics/system_inventory.h"
#include "src/core/platform/cache_directory.hpp"
#include "src/core/platform/os_info.hpp"

namespace {

void TestHostMemoryAndInventory() {
  const auto inventory = gufo::diagnostics::CollectSystemInventory();
  MEMORYSTATUSEX memory{};
  memory.dwLength = sizeof(memory);
  assert(GlobalMemoryStatusEx(&memory));
  assert(inventory.memory.total_bytes == memory.ullTotalPhys);
  assert(inventory.memory.available_bytes > 0);
  assert(inventory.memory.available_bytes <= inventory.memory.total_bytes);
  SYSTEM_INFO system{};
  GetSystemInfo(&system);
  assert(system.dwPageSize > 0);
  assert(gufo::platform::PageSizeBytes() == system.dwPageSize);
  assert(inventory.memory.free_bytes == 0);
  assert(inventory.memory.memory_type == "unknown");
  assert(!inventory.memory.is_unified);
  assert(inventory.cpu.logical_cores ==
         GetActiveProcessorCount(ALL_PROCESSOR_GROUPS));
  assert(!inventory.cpu.model_name.empty() && !inventory.cpu.vendor.empty());
  assert(inventory.cpu.physical_cores > 0 &&
         inventory.cpu.physical_cores <= inventory.cpu.logical_cores);
  assert(inventory.cpu.numa_nodes > 0);
  assert(inventory.gpu.architecture.empty() &&
         inventory.gpu.compute_units == 0);
  assert(inventory.gpu.availability == "uncompiled (ENGINE_ENABLE_HIP=OFF)");
  assert(inventory.toolchain.cxx_compiler.starts_with("Clang "));
  assert(inventory.toolchain.amdgpu_status == "not applicable on Windows");
  assert(inventory.toolchain.rocm_version ==
         "uncompiled (ENGINE_ENABLE_HIP=OFF)");
  assert(inventory.ToHuman().find("Windows Version") != std::string::npos);
  assert(inventory.ToHuman().find("Linux Kernel") == std::string::npos);

  const auto platform = gufo::cli::CollectDiagnostics(
      gufo::diagnostics::LinuxSysfs{}, "platform");
  assert(platform.Status() == gufo::diagnostics::DiagnosticStatus::kPass);
  assert(platform.Compatibility()->items.front().detected_value ==
         "x86_64-windows");
  const auto report = gufo::cli::CollectDiagnostics();
  assert(report.EngineRevision() != "0.1.0");
  assert(report.ToHuman().find("x86_64-windows (Windows ") !=
         std::string::npos);
  assert(report.ToHuman().find("-linux (Linux ") == std::string::npos);
  assert(report.Status() == gufo::diagnostics::DiagnosticStatus::kWarn);
  assert(report.Compatibility()->overall_verdict ==
         gufo::diagnostics::CompatibilityVerdict::kUnknown);
  auto unsupported = inventory;
  unsupported.cpu.architecture = "arm64";
  assert(gufo::diagnostics::EvaluateCompatibility(unsupported, "all")
             .overall_verdict ==
         gufo::diagnostics::CompatibilityVerdict::kUnsupported);

  // Compare live admission queries against surrounding OS observations.
  // Available RAM is volatile; allow 128 MiB of concurrent host activity.
  const auto before = gufo_available_physical_bytes();
  const auto platform_available = gufo::platform::AvailableMemoryBytes();
  const auto budget = gufo::server::HostSnapshotBudgetBytes();
  const auto ceiling = gufo::server::HostSnapshotCeilingBytes();
  const auto after = gufo_available_physical_bytes();
  constexpr auto tolerance = 128ULL * 1024 * 1024;
  const auto lower = std::min(before, after) > tolerance
                         ? std::min(before, after) - tolerance
                         : 0;
  const auto upper = std::max(before, after) + tolerance;
  assert(platform_available > 0 && platform_available <= memory.ullTotalPhys);
  assert(platform_available >= lower && platform_available <= upper);
  assert(budget >= lower / 2 && budget <= upper / 2);
  constexpr auto headroom = gufo::server::kHostSnapshotHeadroomBytes;
  assert(ceiling >= (lower > headroom ? lower - headroom : 0));
  assert(ceiling <= (upper > headroom ? upper - headroom : 0));

  std::istringstream status(gufo::server::Logger::MemoryStatus());
  std::string rss, available;
  status >> rss >> available;
  assert(rss.starts_with("rss_mib="));
  assert(std::stoull(rss.substr(8)) > 0);
  assert(available.starts_with("host_available_mib="));
  assert(std::stoull(available.substr(19)) > 0);
}

void TestFixtureQueries() {
  auto temp =
      (std::filesystem::temp_directory_path() / "gufo-host-XXXXXX").string();
  assert(mkdtemp(temp.data()));
  const std::filesystem::path root(temp);
  const gufo::diagnostics::LinuxSysfs fixture(root / "sys", root / "proc");
  // Explicit fixture roots must not silently fall back to native host data.
  assert(!fixture.QueryCpuInfo() && !fixture.QueryMemInfo());
  std::filesystem::create_directory(root / "proc");
  std::ofstream(root / "proc" / "cpuinfo")
      << "processor : 0\nvendor_id : FixtureVendor\nmodel name : Fixture CPU\n"
         "siblings : 4\ncpu cores : 2\nphysical id : 0\n";
  std::ofstream(root / "proc" / "meminfo")
      << "MemTotal: 10000000 kB\nMemAvailable: 7000000 kB\nMemFree: 1000000 "
         "kB\n";
  const auto cpu = fixture.QueryCpuInfo();
  const auto mem = fixture.QueryMemInfo();
  assert(cpu && cpu->model_name == "Fixture CPU" && cpu->logical_cores == 4 &&
         cpu->physical_cores == 2);
  assert(mem && mem->total_bytes == 10000000ULL * 1024 &&
         mem->available_bytes == 7000000ULL * 1024 &&
         mem->free_bytes == 1000000ULL * 1024);
  std::filesystem::remove_all(root);
}

struct SavedEnvironment {
  const wchar_t* name;
  std::wstring value;
  explicit SavedEnvironment(const wchar_t* key) : name(key) {
    if (const auto* existing = _wgetenv(name))
      value = existing;
  }
  ~SavedEnvironment() { (void)_wputenv_s(name, value.c_str()); }
};

void TestCacheDirectory() {
  const SavedEnvironment xdg(L"XDG_CACHE_HOME"), local(L"LOCALAPPDATA"),
      home(L"HOME");
  auto set = [](const wchar_t* key, const wchar_t* value) {
    assert(_wputenv_s(key, value) == 0);
  };
  const std::filesystem::path unicode(L"C:/Gufo Test/\u7528\u6237");
  set(L"XDG_CACHE_HOME", L"");
  set(L"LOCALAPPDATA", unicode.c_str());
  set(L"HOME", L"C:/fallback home");
  assert(gufo::platform::DefaultCacheDirectory() == unicode / "gufo");
  set(L"XDG_CACHE_HOME", L"C:/explicit cache");
  assert(gufo::platform::DefaultCacheDirectory() ==
         std::filesystem::path(L"C:/explicit cache/gufo"));
  set(L"XDG_CACHE_HOME", L"");
  set(L"LOCALAPPDATA", L"");
  assert(gufo::platform::DefaultCacheDirectory() ==
         std::filesystem::path(L"C:/fallback home/.cache/gufo"));
  set(L"HOME", L"");
  assert(!gufo::platform::DefaultCacheDirectory());
}

}  // namespace

int main() {
  TestHostMemoryAndInventory();
  TestFixtureQueries();
  TestCacheDirectory();
  std::cout << "Windows host integration checks passed\n";
}
