#include "src/core/diagnostics/compatibility.h"

#include <sstream>

namespace gufo::diagnostics {

namespace {

std::string EscapeJsonString(std::string_view str) {
  std::ostringstream oss;
  for (const char ch : str) {
    if (ch == '"') {
      oss << "\\\"";
    } else if (ch == '\\') {
      oss << "\\\\";
    } else if (ch == '\n') {
      oss << "\\n";
    } else {
      oss << ch;
    }
  }
  return oss.str();
}

}  // namespace

std::string_view ToString(CompatibilityVerdict verdict) {
  switch (verdict) {
    case CompatibilityVerdict::kSupported:
      return "supported";
    case CompatibilityVerdict::kUnsupported:
      return "unsupported";
    case CompatibilityVerdict::kUnknown:
      return "unknown";
  }
  return "unknown";
}

CompatibilityReport EvaluateCompatibility(const SystemInventory& inventory,
                                          std::string_view section) {
  CompatibilityReport report;
  CompatibilityVerdict overall = CompatibilityVerdict::kSupported;

  // 1. Platform Check
  if (section == "all" || section == "platform" || section == "inventory") {
    CompatibilityItem platform_item;
    platform_item.component = "platform";
#ifdef _WIN32
    platform_item.detected_value = inventory.cpu.architecture + "-windows";
    platform_item.required_value = "x86_64-windows";
#else
    platform_item.detected_value = inventory.cpu.architecture + "-linux";
    platform_item.required_value = "x86_64-linux";
#endif
    platform_item.evidence = "CPU architecture / host OS";
    if (inventory.cpu.architecture == "x86_64") {
      platform_item.verdict = CompatibilityVerdict::kSupported;
      platform_item.remediation_hint = "None";
    } else {
      platform_item.verdict = CompatibilityVerdict::kUnsupported;
#ifdef _WIN32
      platform_item.remediation_hint = "gufo requires Windows x86-64";
#else
      platform_item.remediation_hint = "gufo only supports Linux x86-64";
#endif
      overall = CompatibilityVerdict::kUnsupported;
    }
    report.items.push_back(std::move(platform_item));
  }

  // 2. GPU Architecture Check (gfx1151)
  if (section == "all" || section == "gpu" || section == "inventory") {
    CompatibilityItem gpu_item;
    gpu_item.component = "gpu";
    gpu_item.detected_value = inventory.gpu.architecture;
    gpu_item.required_value = "gfx1151";
    gpu_item.evidence = inventory.gpu.source;
    if (inventory.gpu.architecture == "gfx1151") {
      gpu_item.verdict = CompatibilityVerdict::kSupported;
      gpu_item.remediation_hint = "None";
#ifdef _WIN32
    } else if (inventory.gpu.architecture.empty()) {
      gpu_item.detected_value = inventory.gpu.availability;
      gpu_item.verdict = CompatibilityVerdict::kUnknown;
      gpu_item.remediation_hint = "GPU detection requires a HIP-enabled build";
      if (overall == CompatibilityVerdict::kSupported)
        overall = CompatibilityVerdict::kUnknown;
#endif
    } else {
      gpu_item.verdict = CompatibilityVerdict::kUnsupported;
      gpu_item.remediation_hint =
          "gufo requires AMD Strix Halo gfx1151 GPU (Radeon 8060S / "
          "8050S). Detected: " +
          inventory.gpu.architecture;
      overall = CompatibilityVerdict::kUnsupported;
    }
    report.items.push_back(std::move(gpu_item));
  }

  // 3. Kernel Driver Check
  if (section == "all" || section == "inventory") {
    CompatibilityItem driver_item;
#ifdef _WIN32
    driver_item.component = "windows_driver";
    driver_item.detected_value = "unavailable";
    driver_item.required_value = "qualified Windows HIP driver";
    driver_item.evidence = inventory.gpu.source;
    driver_item.verdict = CompatibilityVerdict::kUnknown;
    driver_item.remediation_hint =
        "Windows HIP driver qualification is pending";
    if (overall == CompatibilityVerdict::kSupported)
      overall = CompatibilityVerdict::kUnknown;
#else
    driver_item.component = "kernel_driver";
    driver_item.detected_value = "amdgpu: " + inventory.toolchain.amdgpu_status;
    driver_item.required_value = "amdgpu: loaded";
    driver_item.evidence = "/sys/class/drm";
    if (inventory.toolchain.amdgpu_status == "loaded") {
      driver_item.verdict = CompatibilityVerdict::kSupported;
      driver_item.remediation_hint = "None";
    } else {
      driver_item.verdict = CompatibilityVerdict::kUnsupported;
      driver_item.remediation_hint =
          "Ensure Linux kernel >= 6.10 with the amdgpu driver loaded";
      overall = CompatibilityVerdict::kUnsupported;
    }
#endif
    report.items.push_back(std::move(driver_item));
  }

  report.overall_verdict = overall;
  return report;
}

std::string CompatibilityReport::ToJson() const {
  std::ostringstream oss;
  oss << "{\n";
  oss << "  \"overallVerdict\": \"" << ToString(overall_verdict) << "\",\n";
  oss << "  \"items\": [\n";

  for (std::size_t i = 0; i < items.size(); ++i) {
    const auto& item = items[i];
    oss << "    {\n";
    oss << "      \"component\": \"" << EscapeJsonString(item.component)
        << "\",\n";
    oss << "      \"verdict\": \"" << ToString(item.verdict) << "\",\n";
    oss << "      \"detectedValue\": \""
        << EscapeJsonString(item.detected_value) << "\",\n";
    oss << "      \"requiredValue\": \""
        << EscapeJsonString(item.required_value) << "\",\n";
    oss << "      \"evidence\": \"" << EscapeJsonString(item.evidence)
        << "\",\n";
    oss << "      \"remediationHint\": \""
        << EscapeJsonString(item.remediation_hint) << "\"\n";
    oss << "    }";
    if (i + 1 < items.size()) {
      oss << ",";
    }
    oss << "\n";
  }

  oss << "  ]\n";
  oss << "}\n";
  return oss.str();
}

std::string CompatibilityReport::ToHuman() const {
  std::ostringstream oss;
  oss << "=== Compatibility Verdict: [" << ToString(overall_verdict)
      << "] ===\n\n";

  for (const auto& item : items) {
    oss << "  - " << item.component << " [" << ToString(item.verdict) << "]\n";
    oss << "      Detected   : " << item.detected_value << "\n";
    oss << "      Required   : " << item.required_value << "\n";
    if (item.verdict != CompatibilityVerdict::kSupported &&
        !item.remediation_hint.empty() && item.remediation_hint != "None") {
      oss << "      Remediation: " << item.remediation_hint << "\n";
    }
  }

  return oss.str();
}

}  // namespace gufo::diagnostics
