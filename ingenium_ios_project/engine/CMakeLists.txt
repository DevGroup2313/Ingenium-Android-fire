# INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
# NO LICENCE IS GRANTED. See LICENCE.txt.
#
# The native engine for the iPhone and iPad app: llama.cpp (with Metal, the
# Apple graphics chip) and Ingenium's engine, as one static library.
cmake_minimum_required(VERSION 3.22)
project(ingenium_engine C CXX)

set(IE_LLAMA_TAG "b11321")
if(NOT LLAMA_DIR OR NOT EXISTS "${LLAMA_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "LLAMA_DIR must point at a llama.cpp checkout (${IE_LLAMA_TAG})")
endif()
set(IE_NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../native")

set(BUILD_SHARED_LIBS        OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON       ON  CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS        OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS        OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER       OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP          OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL               OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL            OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP              OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE              OFF CACHE BOOL "" FORCE)
set(GGML_METAL               ON  CACHE BOOL "" FORCE)
set(GGML_METAL_EMBED_LIBRARY ON  CACHE BOOL "" FORCE)
set(GGML_METAL_TARGET_OS     ios CACHE STRING "" FORCE)
set(GGML_BLAS_DEFAULT        ON  CACHE BOOL "" FORCE)
add_subdirectory(${LLAMA_DIR} llama EXCLUDE_FROM_ALL)

add_library(ingenium_engine STATIC ${IE_NATIVE_DIR}/ingenium_engine.cpp)
target_include_directories(ingenium_engine PUBLIC ${IE_NATIVE_DIR})
target_compile_definitions(ingenium_engine PRIVATE IE_LLAMA_TAG="${IE_LLAMA_TAG}")
target_link_libraries(ingenium_engine PRIVATE llama-common llama)
