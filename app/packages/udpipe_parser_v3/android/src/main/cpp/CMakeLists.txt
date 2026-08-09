cmake_minimum_required(VERSION 3.18)
project(udpipe_parser_v3 LANGUAGES CXX)

include("${CMAKE_CURRENT_SOURCE_DIR}/../../../../cmake/udpipe_sources.cmake")

add_library(udpipe_parser_v3 SHARED
  ${UDPIPE_LIBRARY_SOURCES}
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../../native/udpipe_parser_v3_core.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/udpipe_parser_v3_jni.cpp")
tomato_configure_udpipe_target(udpipe_parser_v3)
target_include_directories(udpipe_parser_v3 PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../../native")
