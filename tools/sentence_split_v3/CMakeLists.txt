cmake_minimum_required(VERSION 3.18)
project(tomato_udpipe_v3_training LANGUAGES CXX)

include("${CMAKE_CURRENT_LIST_DIR}/../../app/packages/udpipe_parser_v3/cmake/udpipe_sources.cmake")

add_library(tomato_udpipe_core STATIC ${UDPIPE_LIBRARY_SOURCES})
tomato_configure_udpipe_target(tomato_udpipe_core)

add_executable(udpipe_v3_train
  "${UDPIPE_SOURCE_ROOT}/udpipe.cpp"
  "${UDPIPE_SOURCE_ROOT}/utils/options.cpp"
  "${UDPIPE_SOURCE_ROOT}/utils/win_wmain_utf8.cpp")
tomato_configure_udpipe_target(udpipe_v3_train)
target_link_libraries(udpipe_v3_train PRIVATE tomato_udpipe_core)

add_executable(udpipe_v3_probe
  "${CMAKE_CURRENT_LIST_DIR}/probe_main.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/../../app/packages/udpipe_parser_v3/native/udpipe_parser_v3_core.cpp")
tomato_configure_udpipe_target(udpipe_v3_probe)
target_include_directories(udpipe_v3_probe PRIVATE
  "${CMAKE_CURRENT_LIST_DIR}/../../app/packages/udpipe_parser_v3/native")
target_link_libraries(udpipe_v3_probe PRIVATE tomato_udpipe_core)
