#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <bit>
#include <cassert>
#include <cstring>
#include <iostream>
#include <limits>
#include <thread>

#include "src/core/platform/device_memory.hpp"
#include "src/core/platform/device_memory_win32.hpp"

namespace {

void TestBudgetFailuresAndPressure() {
  DXGI_QUERY_VIDEO_MEMORY_INFO local{100, 30, 0, 0}, shared{50, 10, 0, 0};
  int fail = -1, calls = 0;
  auto query = [&](DXGI_MEMORY_SEGMENT_GROUP group,
                   DXGI_QUERY_VIDEO_MEMORY_INFO* info) -> HRESULT {
    ++calls;
    *info = group == DXGI_MEMORY_SEGMENT_GROUP_LOCAL ? local : shared;
    return static_cast<int>(group) == fail ? E_FAIL : S_OK;
  };
  std::size_t free = 11, total = 22;
  assert(gufo::platform::detail::QueryVideoMemoryBudget(query, &free, &total));
  assert(free == 110 && total == 150 && calls == 2);
  // Refresh after the OS reduces the budget; clamp each segment separately.
  local.Budget = 20;
  assert(gufo::platform::detail::QueryVideoMemoryBudget(query, &free, &total));
  assert(free == 40 && total == 70);
  shared.CurrentUsage = 60;
  assert(gufo::platform::detail::QueryVideoMemoryBudget(query, &free, &total));
  assert(free == 0 && total == 70);
  // Failure in either segment, including one writing a partial result, leaves
  // the caller's complete HIP fallback unchanged.
  for (fail = 0; fail <= 1; ++fail) {
    free = 11;
    total = 22;
    assert(
        !gufo::platform::detail::QueryVideoMemoryBudget(query, &free, &total));
    assert(free == 11 && total == 22);
  }
  fail = -1;
  local.Budget = std::numeric_limits<std::size_t>::max();
  shared.Budget = 1;
  assert(!gufo::platform::detail::QueryVideoMemoryBudget(query, &free, &total));
  assert(free == 11 && total == 22);
}

struct Budget {
  std::size_t free{}, total{};
};

Budget ReadBudget(IDXGIAdapter3* adapter, UINT node) {
  DXGI_QUERY_VIDEO_MEMORY_INFO local{}, shared{};
  assert(SUCCEEDED(adapter->QueryVideoMemoryInfo(
      node, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &local)));
  assert(SUCCEEDED(adapter->QueryVideoMemoryInfo(
      node, DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, &shared)));
  // Compute the oracle independently of the production reduction.
  return {local.Budget - std::min(local.Budget, local.CurrentUsage) +
              shared.Budget - std::min(shared.Budget, shared.CurrentUsage),
          local.Budget + shared.Budget};
}

void CheckLiveBudget(IDXGIAdapter3* adapter, UINT node, const char* label) {
  const auto before = ReadBudget(adapter, node);
  Budget actual;
  assert(gufo::platform::DeviceMemoryInfo(&actual.free, &actual.total) ==
         hipSuccess);
  const auto after = ReadBudget(adapter, node);
  // Allow the OS budget to move between the independent and production calls.
  assert(actual.free >= std::min(before.free, after.free) &&
         actual.free <= std::max(before.free, after.free));
  assert(actual.total >= std::min(before.total, after.total) &&
         actual.total <= std::max(before.total, after.total));
  assert(actual.free <= actual.total);
  Budget raw;
  assert(hipMemGetInfo(&raw.free, &raw.total) == hipSuccess);
  std::cout << label << " hip_free=" << raw.free << " hip_total=" << raw.total
            << " budget_free=" << actual.free
            << " budget_total=" << actual.total << std::endl;
}

void TestCurrentAdapter() {
  int devices = 0, original = 0;
  assert(hipGetDeviceCount(&devices) == hipSuccess && devices > 0);
  assert(hipGetDevice(&original) == hipSuccess);
  for (int device = 0; device < devices; ++device) {
    assert(hipSetDevice(device) == hipSuccess);
    hipDeviceProp_t properties{};
    assert(hipGetDeviceProperties(&properties, device) == hipSuccess);
    std::cout << "device=" << device << " arch=" << properties.gcnArchName
              << " integrated=" << properties.integrated
              << " node_mask=" << properties.luidDeviceNodeMask << " luid=";
    for (unsigned char byte : properties.luid)
      std::cout << std::hex << static_cast<unsigned>(byte) << ':';
    std::cout << std::dec << std::endl;
    LUID luid{};
    std::memcpy(&luid, properties.luid, sizeof(luid));
    Microsoft::WRL::ComPtr<IDXGIFactory4> factory;
    assert(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf()))));
    Microsoft::WRL::ComPtr<IDXGIAdapter3> adapter;
    assert(SUCCEEDED(factory->EnumAdapterByLuid(
        luid, IID_PPV_ARGS(adapter.GetAddressOf()))));
    DXGI_ADAPTER_DESC desc{};
    assert(SUCCEEDED(adapter->GetDesc(&desc)));
    assert(std::memcmp(&desc.AdapterLuid, properties.luid, sizeof(luid)) == 0);
    const auto node = properties.luidDeviceNodeMask
                          ? std::countr_zero(properties.luidDeviceNodeMask)
                          : 0;
    CheckLiveBudget(adapter.Get(), node, "before_allocation");
    constexpr std::size_t allocation = 512ULL << 20;
    assert(ReadBudget(adapter.Get(), node).free > 2 * allocation);
    void* storage = nullptr;
    assert(hipMalloc(&storage, allocation) == hipSuccess);
    assert(hipMemset(storage, 0x5a, allocation) == hipSuccess);
    assert(hipDeviceSynchronize() == hipSuccess);
    CheckLiveBudget(adapter.Get(), node, "after_allocation");
    std::thread other([&] {
      assert(hipSetDevice(device) == hipSuccess);
      CheckLiveBudget(adapter.Get(), node, "other_thread");
    });
    other.join();
    assert(hipFree(storage) == hipSuccess);
    CheckLiveBudget(adapter.Get(), node, "after_free");
  }
  assert(hipSetDevice(original) == hipSuccess);
}

void TestHipPointerContract() {
  // TheRock accepts null outputs. Preserve its status and written HIP values
  // for partial queries instead of dereferencing an omitted output.
  for (int omitted = 0; omitted < 3; ++omitted) {
    Budget raw{123, 456}, actual = raw;
    auto* raw_free = omitted == 1 ? &raw.free : nullptr;
    auto* raw_total = omitted == 0 ? &raw.total : nullptr;
    auto* actual_free = omitted == 1 ? &actual.free : nullptr;
    auto* actual_total = omitted == 0 ? &actual.total : nullptr;
    const auto expected = hipMemGetInfo(raw_free, raw_total);
    (void)hipGetLastError();
    assert(gufo::platform::DeviceMemoryInfo(actual_free, actual_total) ==
           expected);
    assert(actual.free == raw.free && actual.total == raw.total);
    (void)hipGetLastError();
  }
}

}  // namespace

int main() {
  TestBudgetFailuresAndPressure();
  TestCurrentAdapter();
  TestHipPointerContract();
  std::cout
      << "PASS: Windows GPU budget, adapter, refresh, and fallback checks\n";
}
