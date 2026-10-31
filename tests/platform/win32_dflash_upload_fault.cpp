// WINDOWS: Reuse the upstream upload-lifetime fixture without ELF --wrap.
// This executable owns its HIP import pointer; production targets are
// untouched.
#include <hip/hip_runtime.h>
#include <windows.h>

#include <cstdlib>

using Copy = hipError_t (*)(void*, const void*, std::size_t, hipMemcpyKind,
                            hipStream_t);

extern "C" hipError_t __wrap_hipMemcpyAsync(void*, const void*, std::size_t,
                                            hipMemcpyKind, hipStream_t);

extern "C" {
extern Copy __imp_hipMemcpyAsync;

hipError_t __real_hipMemcpyAsync(void* destination, const void* source,
                                 std::size_t bytes, hipMemcpyKind kind,
                                 hipStream_t stream) {
  static const auto real = [] {
    const auto module = GetModuleHandleW(L"amdhip64_7.dll");
    if (!module)
      std::abort();
    const auto symbol = GetProcAddress(module, "hipMemcpyAsync");
    if (!symbol)
      std::abort();
    return reinterpret_cast<Copy>(symbol);
  }();
  return real(destination, source, bytes, kind, stream);
}
}

namespace {
struct InstallImportHook {
  InstallImportHook() {
    DWORD previous{};
    if (!VirtualProtect(&__imp_hipMemcpyAsync, sizeof(Copy), PAGE_READWRITE,
                        &previous))
      std::abort();
    __imp_hipMemcpyAsync = __wrap_hipMemcpyAsync;
    DWORD ignored{};
    if (!VirtualProtect(&__imp_hipMemcpyAsync, sizeof(Copy), previous,
                        &ignored))
      std::abort();
  }
} install;
}  // namespace
