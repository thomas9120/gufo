#ifndef GUFO_CORE_PLATFORM_CACHE_DIRECTORY_HPP_
#define GUFO_CORE_PLATFORM_CACHE_DIRECTORY_HPP_

#include <cstdlib>
#include <filesystem>
#include <optional>

namespace gufo::platform {

// Select only; callers must qualify privacy/durability before creating files.
inline std::optional<std::filesystem::path> DefaultCacheDirectory() {
#ifdef _WIN32
  // Read the native wide environment to preserve Unicode user/profile paths.
  const auto* base = _wgetenv(L"XDG_CACHE_HOME");
  if (!base || !*base)
    base = _wgetenv(L"LOCALAPPDATA");
  if (base && *base)
    return std::filesystem::path(base) / "gufo";
  const auto* home = _wgetenv(L"HOME");
#else
  const auto* base = std::getenv("XDG_CACHE_HOME");
  if (base && *base)
    return std::filesystem::path(base) / "gufo";
  const auto* home = std::getenv("HOME");
#endif
  if (home && *home)
    return std::filesystem::path(home) / ".cache" / "gufo";
  return std::nullopt;
}

}  // namespace gufo::platform

#endif  // GUFO_CORE_PLATFORM_CACHE_DIRECTORY_HPP_
