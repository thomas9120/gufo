#include "src/core/platform/device_memory.hpp"

#include <windows.h>
#include <wrl/client.h>

#include <bit>
#include <cstring>
#include <mutex>
#include <string_view>

#include "src/core/platform/device_memory_win32.hpp"

namespace gufo::platform {
namespace {

struct AdapterCache {
  int device{-1};
  UINT node{};
  Microsoft::WRL::ComPtr<IDXGIAdapter3> adapter;

  bool Resolve(int current) noexcept {
    if (device == current && adapter) {
      return true;
    }
    device = -1;
    adapter.Reset();
    hipDeviceProp_t properties{};
    if (hipGetDeviceProperties(&properties, current) != hipSuccess ||
        !properties.integrated) {
      return false;
    }
    const auto mask = properties.luidDeviceNodeMask;
    // TheRock 10.0.0 supplies a LUID but leaves the node mask zero on Strix
    // Halo. That supported single-node APU uses DXGI node zero. An unknown
    // zero/multi-node mask keeps the HIP fallback rather than guessing.
    if (mask ? !std::has_single_bit(mask)
             : !std::string_view(properties.gcnArchName)
                    .starts_with("gfx1151")) {
      return false;
    }
    LUID luid{};
    static_assert(sizeof(luid) == sizeof(properties.luid));
    std::memcpy(&luid, properties.luid, sizeof(luid));
    Microsoft::WRL::ComPtr<IDXGIFactory4> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf()))) ||
        FAILED(factory->EnumAdapterByLuid(
            luid, IID_PPV_ARGS(adapter.GetAddressOf())))) {
      return false;
    }
    node = mask ? std::countr_zero(mask) : 0;
    device = current;
    return true;
  }
};

}  // namespace

hipError_t DeviceMemoryInfo(std::size_t* free_bytes,
                            std::size_t* total_bytes) noexcept {
  const auto status = hipMemGetInfo(free_bytes, total_bytes);
  if (status != hipSuccess || free_bytes == nullptr || total_bytes == nullptr) {
    return status;
  }
  int current = 0;
  if (hipGetDevice(&current) != hipSuccess) {
    return status;
  }
  // HTTP workers can be short lived. Share adapter discovery, while retaining
  // a reference to the correct adapter if another thread changes devices.
  static std::mutex mutex;
  static AdapterCache cache;
  Microsoft::WRL::ComPtr<IDXGIAdapter3> adapter;
  UINT node = 0;
  {
    std::lock_guard lock(mutex);
    if (!cache.Resolve(current)) {
      return status;
    }
    adapter = cache.adapter;
    node = cache.node;
  }
  (void)detail::QueryVideoMemoryBudget(
      [&](DXGI_MEMORY_SEGMENT_GROUP group, DXGI_QUERY_VIDEO_MEMORY_INFO* info) {
        return adapter->QueryVideoMemoryInfo(node, group, info);
      },
      free_bytes, total_bytes);
  return status;
}

}  // namespace gufo::platform
