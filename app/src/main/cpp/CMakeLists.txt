# INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
# NO LICENCE IS GRANTED. See LICENCE.txt.
#
# The native engine for the Android and Fire tablet app: llama.cpp, built for
# the device, with Ingenium's engine (../../../../../native) and its JNI bridge.
cmake_minimum_required(VERSION 3.22.1)
project(ingenium C CXX)

set(IE_LLAMA_TAG "b11321")

if(NOT IE_NATIVE_DIR OR NOT EXISTS "${IE_NATIVE_DIR}/ingenium_engine.cpp")
    message(FATAL_ERROR "IE_NATIVE_DIR must point at the repository's native/ folder")
endif()

# llama.cpp: the copy beside the project when there is one (the cloud build
# puts it there), otherwise fetched once at the pinned release.
if(NOT LLAMA_DIR OR NOT EXISTS "${LLAMA_DIR}/CMakeLists.txt")
    include(FetchContent)
    FetchContent_Declare(llama_cpp
        GIT_REPOSITORY https://github.com/ggml-org/llama.cpp.git
        GIT_TAG        ${IE_LLAMA_TAG}
        GIT_SHALLOW    TRUE)
    FetchContent_GetProperties(llama_cpp)
    if(NOT llama_cpp_POPULATED)
        FetchContent_Populate(llama_cpp)
    endif()
    set(LLAMA_DIR "${llama_cpp_SOURCE_DIR}")
endif()

# R73: on 64-bit devices the processor part of the engine is built several
# times, once for each generation of chip (on ARM: plain v8.0, v8.2 with the
# dot-product instructions, v8.6 with the 8-bit matrix instructions, and the
# newer v9 ones), and the engine loads the fastest one this device supports
# when it starts, as llama.cpp's own Android example does. Before, one build
# for the oldest chips served every device, so newer tablets never used
# their faster instructions. x86_64 (the test emulator) loads its processor
# part the same way, from one build, so the cloud test covers the loading.
# 32-bit ARM keeps the single, static build.
if(ANDROID_ABI STREQUAL "arm64-v8a" OR ANDROID_ABI STREQUAL "x86_64")
    set(IE_CPU_VARIANTS ON)
    set(BUILD_SHARED_LIBS  ON  CACHE BOOL "" FORCE)
    set(GGML_BACKEND_DL    ON  CACHE BOOL "" FORCE)
    set(GGML_LLAMAFILE     OFF CACHE BOOL "" FORCE)
    if(ANDROID_ABI STREQUAL "arm64-v8a")
        set(GGML_CPU_ALL_VARIANTS ON CACHE BOOL "" FORCE)
    endif()
    # the loadable parts land beside libingenium.so, so they are packaged
    if(CMAKE_LIBRARY_OUTPUT_DIRECTORY)
        set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}")
    endif()
else()
    set(IE_CPU_VARIANTS OFF)
    set(BUILD_SHARED_LIBS  OFF CACHE BOOL "" FORCE)
endif()
# 16 KB memory pages (newer Android devices) as well as 4 KB ones, for every
# library the build makes
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384")
set(CMAKE_MODULE_LINKER_FLAGS "${CMAKE_MODULE_LINKER_FLAGS} -Wl,-z,max-page-size=16384")
set(LLAMA_BUILD_COMMON    ON  CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES  OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP       OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL            OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL         OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP           OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE           OFF CACHE BOOL "" FORCE)
if(ANDROID_ABI STREQUAL "armeabi-v7a")
    # llamafile's kernels need half-precision NEON, which 32-bit ARM lacks
    set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
endif()
add_subdirectory(${LLAMA_DIR} llama EXCLUDE_FROM_ALL)

add_library(ingenium SHARED
    ingenium_jni.cpp
    ${IE_NATIVE_DIR}/ingenium_engine.cpp)
target_include_directories(ingenium PRIVATE ${IE_NATIVE_DIR})
target_compile_definitions(ingenium PRIVATE IE_LLAMA_TAG="${IE_LLAMA_TAG}")
if(IE_CPU_VARIANTS)
    target_compile_definitions(ingenium PRIVATE IE_CPU_VARIANTS=1)
endif()
target_link_libraries(ingenium PRIVATE llama-common llama ggml ggml-base android log dl)
target_link_options(ingenium PRIVATE "-Wl,-z,max-page-size=16384")
