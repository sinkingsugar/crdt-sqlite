cmake_minimum_required(VERSION 3.15)
project(crdt-sqlite VERSION 1.0.0 LANGUAGES CXX)

# Set C++ standard
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Compiler warnings
if(MSVC)
  add_compile_options(/W4)
else()
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

# Options
option(BUILD_TESTS "Build tests" ON)

# Find SQLite3 (supports both system packages and custom builds)
find_package(SQLite3)

# If find_package failed, try manual search (for custom SQLite builds)
if(NOT SQLite3_FOUND)
  find_path(SQLite3_INCLUDE_DIR NAMES sqlite3.h
    HINTS ${CMAKE_PREFIX_PATH}/include)
  find_library(SQLite3_LIBRARY NAMES sqlite3
    HINTS ${CMAKE_PREFIX_PATH}/lib)

  if(SQLite3_INCLUDE_DIR AND SQLite3_LIBRARY)
    set(SQLite3_FOUND TRUE)
    add_library(SQLite::SQLite3 UNKNOWN IMPORTED)
    set_target_properties(SQLite::SQLite3 PROPERTIES
      IMPORTED_LOCATION "${SQLite3_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES "${SQLite3_INCLUDE_DIR}")
    message(STATUS "Found SQLite3 (manual): ${SQLite3_LIBRARY}")
  endif()
endif()

if(NOT SQLite3_FOUND)
  message(FATAL_ERROR "SQLite3 not found. Please install SQLite3 development libraries.")
endif()

# CRDT-SQLite library
add_library(crdt_sqlite STATIC
  crdt_sqlite.cpp
  crdt_sqlite.hpp
  record_id_types.hpp
  crdt_types.hpp
)

target_include_directories(crdt_sqlite PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
  $<INSTALL_INTERFACE:include>
)

target_link_libraries(crdt_sqlite PUBLIC
  SQLite::SQLite3
)

# Tests
if(BUILD_TESTS)
  enable_testing()

  # Basic int64_t tests
  add_executable(test_crdt_sqlite test_crdt_sqlite.cpp)
  target_link_libraries(test_crdt_sqlite PRIVATE crdt_sqlite)
  add_test(NAME crdt_sqlite_tests COMMAND test_crdt_sqlite)

  # uint128_t tests (if __uint128_t is supported)
  include(CheckCXXSourceCompiles)
  check_cxx_source_compiles("
    int main() {
      __uint128_t x = 0;
      return 0;
    }
  " HAVE_UINT128)

  if(HAVE_UINT128)
    add_library(crdt_sqlite_uint128 STATIC
      crdt_sqlite.cpp
      crdt_sqlite.hpp
      record_id_types.hpp
      crdt_types.hpp
    )
    target_compile_definitions(crdt_sqlite_uint128 PRIVATE CRDT_RECORD_ID_TYPE=__uint128_t)
    target_link_libraries(crdt_sqlite_uint128 PUBLIC SQLite::SQLite3)

    add_executable(test_crdt_sqlite_uint128 test_crdt_sqlite_uint128.cpp)
    target_compile_definitions(test_crdt_sqlite_uint128 PRIVATE CRDT_RECORD_ID_TYPE=__uint128_t)
    target_link_libraries(test_crdt_sqlite_uint128 PRIVATE crdt_sqlite_uint128)
    add_test(NAME crdt_sqlite_uint128_tests COMMAND test_crdt_sqlite_uint128)

    message(STATUS "uint128_t support: enabled")
  else()
    message(STATUS "uint128_t support: disabled (compiler doesn't support __uint128_t)")
  endif()
endif()

# Print configuration summary
message(STATUS "")
message(STATUS "CRDT-SQLite Configuration:")
message(STATUS "  CMake version: ${CMAKE_VERSION}")
message(STATUS "  C++ standard: ${CMAKE_CXX_STANDARD}")
message(STATUS "  Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "  Build tests: ${BUILD_TESTS}")
message(STATUS "  SQLite3 version: ${SQLite3_VERSION}")
message(STATUS "  SQLite3 libraries: ${SQLite3_LIBRARIES}")
message(STATUS "")
