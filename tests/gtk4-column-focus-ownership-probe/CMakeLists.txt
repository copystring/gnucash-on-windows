cmake_minimum_required(VERSION 3.21)

project(gtk-column-focus-ownership-probe LANGUAGES C)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK4 REQUIRED IMPORTED_TARGET gtk4>=4.12)

add_executable(gtk-column-focus-ownership-probe main.c)
set_target_properties(gtk-column-focus-ownership-probe PROPERTIES
    C_STANDARD 11
    C_STANDARD_REQUIRED YES
    C_EXTENSIONS NO
)
target_compile_options(gtk-column-focus-ownership-probe PRIVATE
    "$<$<C_COMPILER_ID:GNU,Clang>:-Wall>"
    "$<$<C_COMPILER_ID:GNU,Clang>:-Wextra>"
    "$<$<C_COMPILER_ID:GNU,Clang>:-Wpedantic>"
)
target_link_libraries(gtk-column-focus-ownership-probe PRIVATE PkgConfig::GTK4)
