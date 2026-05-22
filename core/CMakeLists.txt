cmake_minimum_required(VERSION 3.18)
project(unitrack VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD          17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_VISIBILITY_PRESET   hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(UT_BUILD_SHARED "Build shared library" OFF)
option(UT_USE_LIBCURL  "Use libcurl for HTTP (otherwise must inject transport)" OFF)
option(UT_BUILD_TESTS  "Build test runner"    OFF)
option(UT_USE_BUNDLED_SQLITE "Build with bundled sqlite3 amalgamation" ON)

set(UT_SOURCES
    src/event.cpp
    src/logger.cpp
    src/util.cpp
    src/config.cpp
    src/offline_queue.cpp
    src/transport.cpp
    src/session_manager.cpp
    src/crash_handler.cpp
    src/tracker.cpp
    src/capi.cpp
)

if(UT_BUILD_SHARED)
    add_library(unitrack SHARED ${UT_SOURCES})
else()
    add_library(unitrack STATIC ${UT_SOURCES})
endif()

target_include_directories(unitrack
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# ─── SQLite ────────────────────────────────────────────────────────────────
if(UT_USE_BUNDLED_SQLITE)
    if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/third_party/sqlite3/sqlite3.c)
        target_sources(unitrack PRIVATE third_party/sqlite3/sqlite3.c)
        target_include_directories(unitrack PRIVATE third_party/sqlite3)
        target_compile_definitions(unitrack PRIVATE
            SQLITE_THREADSAFE=1
            SQLITE_OMIT_LOAD_EXTENSION=1
            SQLITE_DEFAULT_MEMSTATUS=0
        )
    else()
        message(STATUS "Bundled sqlite3 not found, falling back to system")
        find_package(SQLite3 REQUIRED)
        target_link_libraries(unitrack PRIVATE SQLite::SQLite3)
    endif()
else()
    find_package(SQLite3 REQUIRED)
    target_link_libraries(unitrack PRIVATE SQLite::SQLite3)
endif()

# ─── libcurl (optional) ────────────────────────────────────────────────────
if(UT_USE_LIBCURL)
    find_package(CURL REQUIRED)
    target_link_libraries(unitrack PRIVATE CURL::libcurl)
    target_compile_definitions(unitrack PRIVATE UT_USE_LIBCURL=1)
endif()

# Platform deps
if(ANDROID)
    target_link_libraries(unitrack PRIVATE log)
endif()

if(UNIX AND NOT APPLE AND NOT ANDROID)
    target_link_libraries(unitrack PRIVATE pthread dl)
endif()

# Make the core symbols visible across the C boundary.
target_compile_definitions(unitrack PRIVATE UT_BUILDING=1)

# ─── Tests ─────────────────────────────────────────────────────────────────
if(UT_BUILD_TESTS)
    enable_testing()
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../tests tests)
endif()

# ─── Install ───────────────────────────────────────────────────────────────
include(GNUInstallDirs)
install(TARGETS unitrack
        EXPORT  unitrack-targets
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
