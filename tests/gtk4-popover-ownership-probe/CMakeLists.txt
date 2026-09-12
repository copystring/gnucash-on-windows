cmake_minimum_required(VERSION 3.21)

project(gtk-popover-ownership-probe LANGUAGES C)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK4 REQUIRED IMPORTED_TARGET gtk4)

add_executable(gtk-popover-ownership-probe main.c)
set_target_properties(gtk-popover-ownership-probe PROPERTIES
    C_STANDARD 11
    C_STANDARD_REQUIRED YES
    C_EXTENSIONS NO
)
target_compile_options(gtk-popover-ownership-probe PRIVATE
    "$<$<C_COMPILER_ID:GNU,Clang>:-Wall>"
    "$<$<C_COMPILER_ID:GNU,Clang>:-Wextra>"
    "$<$<C_COMPILER_ID:GNU,Clang>:-Wpedantic>"
)
target_link_libraries(gtk-popover-ownership-probe PRIVATE PkgConfig::GTK4)
