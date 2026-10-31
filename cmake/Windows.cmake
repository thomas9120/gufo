# Native Windows source builds use clang with the MSVC STL/SDK.
# Keep the POSIX headers and libraries confined to Gufo-owned targets.
if (NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang" OR NOT CMAKE_CXX_SIMULATE_ID STREQUAL "MSVC")
  message(FATAL_ERROR "Windows builds require clang targeting the MSVC ABI; use tools/windows/build.ps1")
endif()
# HIP is enabled by default (ENGINE_ENABLE_HIP is declared after this module).
# The HIP compiler probe runs in the root file, so the MSVC <cmath> workaround
# in compat/win32/hip_include must be on the HIP flags before that probe.
if (NOT DEFINED ENGINE_ENABLE_HIP OR ENGINE_ENABLE_HIP)
  if (NOT CMAKE_HIP_FLAGS MATCHES "compat/win32/hip_include")
    set(CMAKE_HIP_FLAGS
      "${CMAKE_HIP_FLAGS} -I\"${PROJECT_SOURCE_DIR}/compat/win32/hip_include\""
      CACHE STRING "HIP flags" FORCE)
  endif()
  if (DEFINED ENV{HIP_PATH})
    file(TO_CMAKE_PATH "$ENV{HIP_PATH}" GUFO_HIP_PATH)
    list(APPEND CMAKE_PREFIX_PATH "${GUFO_HIP_PATH}")
  endif()
endif()
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
add_library(gufo_posix_compat STATIC
  ${PROJECT_SOURCE_DIR}/compat/win32/posix.cpp
  ${PROJECT_SOURCE_DIR}/compat/win32/filesystem.cpp
  ${PROJECT_SOURCE_DIR}/compat/win32/directory.cpp
  ${PROJECT_SOURCE_DIR}/compat/win32/spawn.cpp)
target_include_directories(gufo_posix_compat SYSTEM BEFORE PUBLIC
  ${PROJECT_SOURCE_DIR}/compat/win32/include)
target_compile_definitions(gufo_posix_compat PUBLIC
  _CRT_DECLARE_NONSTDC_NAMES=0 WIN32_LEAN_AND_MEAN NOMINMAX
  _CRT_SECURE_NO_WARNINGS _USE_MATH_DEFINES)
target_link_libraries(gufo_posix_compat PUBLIC ws2_32 psapi advapi32)
file(GENERATE OUTPUT ${CMAKE_BINARY_DIR}/win32-compat-links-$<CONFIG>.txt CONTENT
  "$<TARGET_PROPERTY:gufo_posix_compat,LINK_LIBRARIES>\n$<TARGET_PROPERTY:gufo_posix_compat,INTERFACE_LINK_LIBRARIES>\n")

function(gufo_windows_targets directory)
  get_property(targets DIRECTORY "${directory}" PROPERTY BUILDSYSTEM_TARGETS)
  foreach(target IN LISTS targets)
    get_target_property(type ${target} TYPE)
    if (NOT target STREQUAL "gufo_posix_compat" AND NOT type STREQUAL "UTILITY")
      target_link_libraries(${target} PRIVATE gufo_posix_compat)
      if (type STREQUAL "EXECUTABLE")
        target_link_options(${target} PRIVATE LINKER:/STACK:8388608)
      endif()
    endif()
  endforeach()
  get_property(children DIRECTORY "${directory}" PROPERTY SUBDIRECTORIES)
  foreach(child IN LISTS children)
    gufo_windows_targets("${child}")
  endforeach()
endfunction()
cmake_language(DEFER CALL gufo_windows_targets "${PROJECT_SOURCE_DIR}")

# Resolve after the root file has enabled HIP and created gufo_core. Keep
# DXGI/HIP out of the CPU shim and the common cache's dependency graph.
function(gufo_windows_device_memory)
  if (ENGINE_ENABLE_HIP)
    add_library(gufo_device_memory STATIC
      ${PROJECT_SOURCE_DIR}/src/core/platform/device_memory.cpp)
    target_include_directories(gufo_device_memory PUBLIC ${PROJECT_SOURCE_DIR})
    target_link_libraries(gufo_device_memory PUBLIC hip::host PRIVATE dxgi)
    target_compile_definitions(gufo_device_memory PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
    target_link_libraries(gufo_core PRIVATE gufo_device_memory)
    # Flash-Next's MMQ kernels allocate scratch through managed_alloc.hpp.
    target_link_libraries(gufo_qwen38_flash_next_mmq PRIVATE gufo_device_memory)
    if (BUILD_TESTING)
      add_executable(qwen38_flash_next_win32_yarn_snapshot_test EXCLUDE_FROM_ALL
        ${PROJECT_SOURCE_DIR}/tests/models/qwen38_flash_next/win32_yarn_snapshot_test.cpp)
      target_link_libraries(qwen38_flash_next_win32_yarn_snapshot_test PRIVATE
        gufo_qwen38_flash_next)
      add_executable(win32_device_memory_test
        ${PROJECT_SOURCE_DIR}/tests/platform/win32_device_memory_test.cpp)
      target_compile_options(win32_device_memory_test PRIVATE -UNDEBUG)
      target_compile_definitions(win32_device_memory_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
      target_link_libraries(win32_device_memory_test PRIVATE gufo_device_memory dxgi)
      add_test(NAME win32_device_memory_test COMMAND win32_device_memory_test)
      set_tests_properties(win32_device_memory_test PROPERTIES LABELS "gpu;windows" TIMEOUT 30)
      # The Linux backing test uses ELF --wrap fault hooks. Exercise the real
      # pinned-memory/transfer paths here without changing those Linux hooks.
      add_executable(win32_pinned_transfer_test
        ${PROJECT_SOURCE_DIR}/tests/platform/win32_pinned_transfer_test.cpp)
      target_compile_options(win32_pinned_transfer_test PRIVATE -UNDEBUG)
      target_link_libraries(win32_pinned_transfer_test PRIVATE gufo_cache_hip Threads::Threads)
      add_test(NAME win32_pinned_transfer_test COMMAND win32_pinned_transfer_test)
      set_tests_properties(win32_pinned_transfer_test PROPERTIES
        LABELS "hip;gpu;gfx1151;windows;cache" TIMEOUT 60)
    endif()
  endif()
endfunction()
cmake_language(DEFER CALL gufo_windows_device_memory)

# Override upstream root targets after they exist, so their lines stay
# unchanged. The cache fault library interposes libc through LD_PRELOAD and
# has no Windows equivalent; check-pr, which depends on it, is Linux-only.
# The upstream gufo-server symlink install step fails harmlessly here
# (execute_process ignores the exit status); install a copy instead.
function(gufo_windows_overrides)
  if (TARGET qwen_dflash_upload_lifetime_test)
    # WINDOWS: Run upstream's upload-failure fixture without ELF --wrap.
    set_property(TARGET qwen_dflash_upload_lifetime_test PROPERTY LINK_OPTIONS
      "LINKER:/STACK:8388608")
    target_sources(qwen_dflash_upload_lifetime_test PRIVATE
      ${PROJECT_SOURCE_DIR}/tests/platform/win32_dflash_upload_fault.cpp)
  endif()
  if (TARGET cache_disk_faults)
    set_target_properties(cache_disk_faults PROPERTIES EXCLUDE_FROM_ALL TRUE)
  endif()
  if (TEST cache_disk_faults_test)
    set_tests_properties(cache_disk_faults_test PROPERTIES DISABLED TRUE)
  endif()
  install(PROGRAMS $<TARGET_FILE:gufo> DESTINATION bin RENAME gufo-server.exe)
endfunction()
cmake_language(DEFER CALL gufo_windows_overrides)

if (BUILD_TESTING)
  # Called from tests/cache so the test keeps its upstream name and directory.
  function(gufo_windows_cache_boundary)
    add_test(NAME cache_boundary_test
      COMMAND ${Python3_EXECUTABLE} ${PROJECT_SOURCE_DIR}/tests/platform/win32_cache_boundary_test.py
        ${CMAKE_CURRENT_SOURCE_DIR}/boundary_test.py
        ${PROJECT_SOURCE_DIR}/src/cache
        ${CMAKE_CURRENT_BINARY_DIR}/cache-links-$<CONFIG>.txt
        ${CMAKE_BINARY_DIR}/win32-compat-links-$<CONFIG>.txt)
  endfunction()
  target_compile_definitions(gufo_posix_compat PRIVATE GUFO_WIN32_TESTING=1)
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  add_executable(win32_compat_test ${PROJECT_SOURCE_DIR}/tests/platform/win32_compat_test.cpp)
  target_compile_options(win32_compat_test PRIVATE -UNDEBUG)
  target_link_libraries(win32_compat_test PRIVATE gufo_cache)
  add_test(NAME win32_compat_test COMMAND win32_compat_test)
  set_tests_properties(win32_compat_test PROPERTIES LABELS "cpu;windows" TIMEOUT 30)
  add_executable(win32_filesystem_test ${PROJECT_SOURCE_DIR}/tests/platform/win32_filesystem_test.cpp)
  target_compile_options(win32_filesystem_test PRIVATE -UNDEBUG)
  target_compile_definitions(win32_filesystem_test PRIVATE GUFO_WIN32_TESTING=1)
  target_include_directories(win32_filesystem_test PRIVATE ${PROJECT_SOURCE_DIR})
  target_link_libraries(win32_filesystem_test PRIVATE gufo_posix_compat)
  add_test(NAME win32_filesystem_test COMMAND win32_filesystem_test)
  set_tests_properties(win32_filesystem_test PROPERTIES LABELS "cpu;windows;filesystem" TIMEOUT 30)
  add_executable(win32_disk_store_test ${PROJECT_SOURCE_DIR}/tests/platform/win32_disk_store_test.cpp)
  target_compile_options(win32_disk_store_test PRIVATE -UNDEBUG)
  target_compile_definitions(win32_disk_store_test PRIVATE GUFO_WIN32_TESTING=1)
  target_link_libraries(win32_disk_store_test PRIVATE gufo_cache)
  add_test(NAME win32_disk_store_test COMMAND win32_disk_store_test)
  set_tests_properties(win32_disk_store_test PROPERTIES LABELS "cpu;windows;cache" TIMEOUT 60)
  add_executable(win32_host_test
    ${PROJECT_SOURCE_DIR}/tests/platform/win32_host_test.cpp
    ${PROJECT_SOURCE_DIR}/src/cli/serve/continuation_cache.cpp
    ${PROJECT_SOURCE_DIR}/src/cli/serve/continuation_disk_store.cpp
    ${PROJECT_SOURCE_DIR}/src/cli/serve/component_text_cache.cpp
    ${PROJECT_SOURCE_DIR}/src/cli/serve/text_model_runner.cpp)
  # Created before enable_language(HIP) in the root file, so the global
  # CMAKE_HIP_ARCHITECTURES initializer has not run for this target yet.
  set_target_properties(win32_host_test PROPERTIES HIP_ARCHITECTURES gfx1151)
  target_compile_options(win32_host_test PRIVATE -UNDEBUG)
  target_link_libraries(win32_host_test PRIVATE gufo_diagnostics gufo_logging gufo_core gufo_cache)
  add_test(NAME win32_host_test COMMAND win32_host_test)
  set_tests_properties(win32_host_test PROPERTIES LABELS "cpu;windows;diagnostics" TIMEOUT 30)
  add_test(NAME win32_server_shutdown_test
    COMMAND ${Python3_EXECUTABLE} ${PROJECT_SOURCE_DIR}/tests/platform/win32_server_shutdown_test.py
      $<TARGET_FILE:http_server_test>)
  set_tests_properties(win32_server_shutdown_test PROPERTIES LABELS "cpu;windows;server" TIMEOUT 30)
  add_test(NAME win32_queue_policy_test
    COMMAND ${Python3_EXECUTABLE} ${PROJECT_SOURCE_DIR}/tests/platform/win32_queue_policy_test.py
      $<TARGET_FILE:gufo>)
  set_tests_properties(win32_queue_policy_test PROPERTIES LABELS "cpu;windows;server;diagnostics" TIMEOUT 30)
endif()
