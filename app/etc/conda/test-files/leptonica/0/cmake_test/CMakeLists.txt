project(cf_dummy LANGUAGES C CXX)
cmake_minimum_required(VERSION 3.12)

# extracted from https://github.com/tesseract-ocr/tesseract/blob/5.5.1/CMakeLists.txt

# if/once leptonica is built via CMake also on unix, this whole section can be replaced by
# find_package(Leptonica REQUIRED)

find_package(PkgConfig)
find_package(Leptonica CONFIG)
if(NOT Leptonica_FOUND AND PKG_CONFIG_EXECUTABLE)
    pkg_check_modules(Leptonica lept)
    link_directories(${Leptonica_LIBRARY_DIRS})
endif()
if(NOT Leptonica_FOUND)
    message(FATAL_ERROR "Cannot find required library Leptonica. Quitting!")
else()
    message(STATUS "Found leptonica version: ${Leptonica_VERSION}")
endif(NOT Leptonica_FOUND)
include_directories(${Leptonica_INCLUDE_DIRS})

# this check actually tries to link the library
include(${CMAKE_CURRENT_LIST_DIR}/CheckFunctions.cmake)
check_leptonica_tiff_support()
