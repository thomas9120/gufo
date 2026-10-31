#ifndef GUFO_CORE_PLATFORM_DEVICE_MEMORY_WIN32_HPP_
#define GUFO_CORE_PLATFORM_DEVICE_MEMORY_WIN32_HPP_

#include <dxgi1_4.h>

#include <cstddef>
#include <limits>

namespace gufo::platform::detail {

// Commit both segment groups together: a failed/partial query must leave the
// caller's HIP fallback intact. Over-budget segments have no headroom.
template<typename Query>
bool QueryVideoMemoryBudget(Query&& query, std::size_t* free_bytes,
                            std::size_t* total_bytes) noexcept {
  DXGI_QUERY_VIDEO_MEMORY_INFO local{}, shared{};
  if (FAILED(query(DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &local)) ||
      FAILED(query(DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, &shared))) {
    return false;
  }
  constexpr auto max = std::numeric_limits<std::size_t>::max();
  if (shared.Budget > max - local.Budget) {
    return false;
  }
  const auto available = [](const DXGI_QUERY_VIDEO_MEMORY_INFO& info) {
    return info.Budget > info.CurrentUsage ? info.Budget - info.CurrentUsage
                                           : 0;
  };
  *free_bytes = available(local) + available(shared);
  *total_bytes = local.Budget + shared.Budget;
  return true;
}

}  // namespace gufo::platform::detail

#endif  // GUFO_CORE_PLATFORM_DEVICE_MEMORY_WIN32_HPP_
