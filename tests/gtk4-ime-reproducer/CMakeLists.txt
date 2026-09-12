cmake_minimum_required (VERSION 3.21)

project (gtk-ime-window-lifetime-repro C)

find_package (PkgConfig REQUIRED)
pkg_check_modules (GTK4 REQUIRED IMPORTED_TARGET gtk4>=4.24)

add_executable (gtk-ime-window-lifetime-repro main.c)
target_compile_options (gtk-ime-window-lifetime-repro
                        PRIVATE -Wall -Wextra -Werror)
target_link_libraries (gtk-ime-window-lifetime-repro PRIVATE PkgConfig::GTK4)
set_target_properties (gtk-ime-window-lifetime-repro PROPERTIES
                       C_STANDARD 11
                       C_STANDARD_REQUIRED YES)
