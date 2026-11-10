# PdfCraft HarmonyOS —— C++ 胶水层构建脚本
#
# 两件事：
#   1. 把 Rust 静态库（libpdfcraft_ohos.a：PDF 核心 + C-ABI 桥）链进来
#   2. napi_bridge.cpp 把它包成 JS 函数（libentry.so）
#
# PdfCraft 的 PDF 核心是纯 Rust（hayro/skrifa/lopdf/kurbo），没有 opus/vpx/aom/sodium
# 那类 C 依赖，所以这里只链接 Rust 静态库本身 + OHOS NAPI/系统库。
#
# Rust 库由 scripts/ohos/build-core.sh 先构建（cargo build --target <ohos> -p pdfcraft-ohos）。

cmake_minimum_required(VERSION 3.5.0)
project(pdfcraft_ohos)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 仓库根：ohos-app/entry/src/main/cpp → 上 5 层
get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)

# DevEco 的 OHOS_ARCH（arm64-v8a / x86_64）→ Rust target
if(OHOS_ARCH STREQUAL "arm64-v8a")
    set(_rust_target "aarch64-unknown-linux-ohos")
elseif(OHOS_ARCH STREQUAL "x86_64")
    set(_rust_target "x86_64-unknown-linux-ohos")
else()
    message(FATAL_ERROR "Unsupported OHOS_ARCH: ${OHOS_ARCH}")
endif()

# Rust 静态库：release 优先（性能 + 体积），回退 debug。
if(NOT DEFINED PDFC_RUST_LIB)
    set(_cand_release "${REPO_ROOT}/target/${_rust_target}/release/libpdfcraft_ohos.a")
    set(_cand_debug   "${REPO_ROOT}/target/${_rust_target}/debug/libpdfcraft_ohos.a")
    if(EXISTS "${_cand_release}")
        set(PDFC_RUST_LIB "${_cand_release}")
    elseif(EXISTS "${_cand_debug}")
        set(PDFC_RUST_LIB "${_cand_debug}")
    else()
        message(FATAL_ERROR
            "libpdfcraft_ohos.a not found. Build it first:\n"
            "  cargo build --target ${_rust_target} -p pdfcraft-ohos --release\n"
            "(tried release and debug under ${REPO_ROOT}/target/${_rust_target}/)")
    endif()
endif()

message(STATUS "PdfCraft: OHOS_ARCH=${OHOS_ARCH} target=${_rust_target}")
message(STATUS "PdfCraft: lib=${PDFC_RUST_LIB}")

add_library(pdfcraft_core STATIC IMPORTED)
set_target_properties(pdfcraft_core PROPERTIES IMPORTED_LOCATION "${PDFC_RUST_LIB}")

add_library(entry SHARED napi_bridge.cpp)

target_include_directories(entry PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# Rust 静态库用 --start-group 包住（rustc 各 CGU 间有循环引用）；-Bsymbolic 让 .so 内
# 符号本地绑定。
target_link_libraries(entry PUBLIC
    -Wl,--start-group
    ${PDFC_RUST_LIB}
    -Wl,--end-group
    -Wl,-Bsymbolic
)

target_link_libraries(entry PUBLIC
    libace_napi.z.so      # napi
    libhilog_ndk.z.so     # OH_LOG_*
    libtime_service_ndk.so # OH_TimeService_GetTimeZone（iana_time_zone→chrono/time 需要）
    libc++_shared.so
    libdl.so
    libm.so
)
