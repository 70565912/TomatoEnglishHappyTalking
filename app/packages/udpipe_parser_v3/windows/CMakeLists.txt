cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "udpipe_parser_v3")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "udpipe_parser_v3_plugin")
include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/udpipe_sources.cmake")

add_library(tomato_udpipe_v3_core STATIC
  ${UDPIPE_LIBRARY_SOURCES}
  "${CMAKE_CURRENT_SOURCE_DIR}/../native/udpipe_parser_v3_core.cpp")
tomato_configure_udpipe_target(tomato_udpipe_v3_core)
target_include_directories(tomato_udpipe_v3_core PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/../native")

add_library(${PLUGIN_NAME} SHARED
  "udpipe_parser_v3_plugin.cpp")
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  tomato_udpipe_v3_core)

set(udpipe_parser_v3_bundled_libraries "" PARENT_SCOPE)

