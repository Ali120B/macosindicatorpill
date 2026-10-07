cmake_minimum_required(VERSION 3.27)
project(macospills-caret-bridge)

find_package(PkgConfig REQUIRED)
pkg_check_modules(HYPRLAND REQUIRED hyprland)
pkg_check_modules(PIXMAN REQUIRED pixman-1)
pkg_check_modules(WAYLAND REQUIRED wayland-server)

add_library(macospills-caret-bridge SHARED main.cpp)

target_include_directories(macospills-caret-bridge PRIVATE ${HYPRLAND_INCLUDE_DIRS} ${PIXMAN_INCLUDE_DIRS} ${WAYLAND_INCLUDE_DIRS})
target_compile_options(macospills-caret-bridge PRIVATE -O2 -fPIC -std=c++23
  ${HYPRLAND_CFLAGS_OTHER} ${PIXMAN_CFLAGS_OTHER} ${WAYLAND_CFLAGS_OTHER})
target_compile_definitions(macospills-caret-bridge PRIVATE ${HYPRLAND_CFLAGS_OTHER})
target_link_options(macospills-caret-bridge PRIVATE -shared)

set_target_properties(macospills-caret-bridge PROPERTIES
  PREFIX ""
  SUFFIX ".so"
  OUTPUT_NAME "macospills-caret-bridge")
