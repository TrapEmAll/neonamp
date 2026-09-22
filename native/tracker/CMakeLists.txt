include(FetchContent)

if(POLICY CMP0169)
  cmake_policy(SET CMP0169 OLD)
endif()

FetchContent_Declare(
  libxmp
  GIT_REPOSITORY https://github.com/libxmp/libxmp.git
  GIT_TAG a13276d27feabcf9ee4f982913f718ee05a65cb7
  GIT_SHALLOW TRUE
)
FetchContent_GetProperties(libxmp)
if(NOT libxmp_POPULATED)
  FetchContent_Populate(libxmp)
endif()

# Build libxmp's upstream source lists directly so its install rules do not
# become part of Flutter's executable-bundle installation step.
set(LIBXMP_DEFINES)
set(LIBXMPLITE_DEFINES)
set(LIBXMP_CFLAGS)
include("${libxmp_SOURCE_DIR}/cmake/libxmp-checks.cmake")
include("${libxmp_SOURCE_DIR}/cmake/libxmp-sources.cmake")
list(APPEND LIBXMP_SRC_LIST ${LIBXMP_SRC_LIST_DEPACKERS} ${LIBXMP_SRC_LIST_PROWIZARD})
list(TRANSFORM LIBXMP_SRC_LIST PREPEND "${libxmp_SOURCE_DIR}/")
if(MSVC)
  list(APPEND LIBXMP_DEFINES _USE_MATH_DEFINES)
else()
  list(APPEND LIBXMP_DEFINES _REENTRANT)
endif()

add_library(xmp_static STATIC ${LIBXMP_SRC_LIST})
set_target_properties(xmp_static PROPERTIES C_STANDARD 90 POSITION_INDEPENDENT_CODE ON)
target_compile_options(xmp_static PRIVATE ${LIBXMP_CFLAGS})
target_compile_definitions(xmp_static PRIVATE ${LIBXMP_DEFINES} PUBLIC LIBXMP_STATIC)
target_include_directories(xmp_static PUBLIC "${libxmp_SOURCE_DIR}/include")
if(LIBM_REQUIRED)
  target_link_libraries(xmp_static PUBLIC ${LIBM_LIBRARY})
endif()

add_library(neonamp_tracker_codec STATIC src/tracker_decoder.cpp)
target_compile_features(neonamp_tracker_codec PUBLIC cxx_std_17)
target_include_directories(neonamp_tracker_codec PUBLIC include)
target_link_libraries(neonamp_tracker_codec PUBLIC xmp_static)

option(NEONAMP_BUILD_TRACKER_TESTS "Build native tracker decoder tests" OFF)
if(NEONAMP_BUILD_TRACKER_TESTS AND NOT ANDROID)
  enable_testing()
  add_executable(tracker_decoder_test tests/tracker_decoder_test.cpp)
  target_link_libraries(tracker_decoder_test PRIVATE neonamp_tracker_codec)
  add_test(NAME tracker_decoder_test COMMAND tracker_decoder_test)
endif()
