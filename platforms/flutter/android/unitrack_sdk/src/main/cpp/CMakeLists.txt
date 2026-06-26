cmake_minimum_required(VERSION 3.22)
project(unitrack_jni LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD          17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Path tới C++ core. Plugin Flutter Android VENDOR core vào subfolder
# `cpp/core/` (via sync_native.sh) để consumer Flutter app build qua
# dependency_overrides:path: hoặc qua pub.dev cache đều thấy được core
# self-contained. KHÔNG dùng relative-out-of-plugin path nữa — chỉ work
# khi build từ monorepo direct, fail mọi consumer khác.
set(UT_CORE_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/core)

# Build the core static library into our shared lib.
set(UT_CORE_SOURCES
    ${UT_CORE_ROOT}/src/event.cpp
    ${UT_CORE_ROOT}/src/logger.cpp
    ${UT_CORE_ROOT}/src/util.cpp
    ${UT_CORE_ROOT}/src/config.cpp
    ${UT_CORE_ROOT}/src/offline_queue.cpp
    ${UT_CORE_ROOT}/src/transport.cpp
    ${UT_CORE_ROOT}/src/session_manager.cpp
    ${UT_CORE_ROOT}/src/crash_handler.cpp
    ${UT_CORE_ROOT}/src/trace_context.cpp
    ${UT_CORE_ROOT}/src/tracker.cpp
    ${UT_CORE_ROOT}/src/capi.cpp
)

add_library(unitrack_jni SHARED
    ${UT_CORE_SOURCES}
    jni_bridge.cpp
)

target_include_directories(unitrack_jni PRIVATE
    ${UT_CORE_ROOT}/include
    ${UT_CORE_ROOT}/src
)

# Use the NDK's bundled sqlite (libsqlite is not in the NDK; we need a
# vendored amalgamation or to link the system one via JNI->Java SQLite
# which is overkill). Easiest: ship bundled amalgamation under
# core/third_party/sqlite3/{sqlite3.c,sqlite3.h}. The release.sh script
# downloads it on first build.
if(EXISTS ${UT_CORE_ROOT}/third_party/sqlite3/sqlite3.c)
    target_sources(unitrack_jni PRIVATE ${UT_CORE_ROOT}/third_party/sqlite3/sqlite3.c)
    target_include_directories(unitrack_jni PRIVATE
        ${UT_CORE_ROOT}/third_party/sqlite3)
    target_compile_definitions(unitrack_jni PRIVATE
        SQLITE_THREADSAFE=1
        SQLITE_OMIT_LOAD_EXTENSION=1
        SQLITE_DEFAULT_MEMSTATUS=0
    )
else()
    message(FATAL_ERROR
      "core/third_party/sqlite3/sqlite3.{c,h} not found. "
      "Run scripts/fetch_sqlite.sh first.")
endif()

find_library(log-lib log)
target_link_libraries(unitrack_jni ${log-lib})
