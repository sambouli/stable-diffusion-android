cmake_minimum_required(VERSION 3.22)

# Thin wrapper around the stable-diffusion.cpp submodule so that
#   cmake -S . -B build ... && cmake --build build
# produces libstable-diffusion.so for Android without callers having to know
# where the engine lives. All engine options are passed straight through.

project(stable-diffusion-android NONE)

if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/sdcpp/CMakeLists.txt")
  message(FATAL_ERROR
    "sdcpp/ is empty. Fetch submodules first:\n"
    "  git submodule update --init --recursive")
endif()

add_subdirectory(sdcpp)
