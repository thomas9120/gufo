#ifndef GUFO_CORE_PLATFORM_DEVICE_MEMORY_HPP_
#define GUFO_CORE_PLATFORM_DEVICE_MEMORY_HPP_

#include <hip/hip_runtime.h>

#include <cstddef>

namespace gufo::platform {

// Windows UMA admission uses the current HIP adapter's WDDM budget. If that
// budget cannot be queried, retain HIP's result, including runtime errors.
#ifdef _WIN32
hipError_t DeviceMemoryInfo(std::size_t* free_bytes,
                            std::size_t* total_bytes) noexcept;
#else
inline hipError_t DeviceMemoryInfo(std::size_t* free_bytes,
                                   std::size_t* total_bytes) noexcept {
  return hipMemGetInfo(free_bytes, total_bytes);
}
#endif

}  // namespace gufo::platform

#endif  // GUFO_CORE_PLATFORM_DEVICE_MEMORY_HPP_
