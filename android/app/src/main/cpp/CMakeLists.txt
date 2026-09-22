cmake_minimum_required(VERSION 3.14)
project(neonamp_tracker LANGUAGES C CXX)

add_subdirectory(
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/tracker"
  "${CMAKE_CURRENT_BINARY_DIR}/tracker")

add_library(neonamp_tracker SHARED android_jni.cpp)
target_compile_features(neonamp_tracker PRIVATE cxx_std_17)
target_link_libraries(neonamp_tracker PRIVATE neonamp_tracker_codec log)
