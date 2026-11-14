cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "vpn_service")
project(${PROJECT_NAME} LANGUAGES CXX)

add_library(${PROJECT_NAME}_plugin vpn_service_plugin.cpp)
apply_standard_settings(${PROJECT_NAME}_plugin)
set_target_properties(${PROJECT_NAME}_plugin PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PROJECT_NAME}_plugin PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PROJECT_NAME}_plugin INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PROJECT_NAME}_plugin PRIVATE flutter flutter_wrapper_plugin)

set(vpn_service_bundled_libraries
  ""
  PARENT_SCOPE
)
