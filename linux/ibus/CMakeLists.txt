cmake_minimum_required(VERSION 3.16)
project(misstype-ibus VERSION 0.1 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

include(GNUInstallDirs)
find_package(PkgConfig REQUIRED)
pkg_check_modules(IBUS REQUIRED ibus-1.0)

get_filename_component(MISSTYPE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

# Directory holding libMisstypeCAPI.so (built by script/linux/build_capi.sh).
set(MISSTYPE_CAPI_DIR "" CACHE PATH "Directory containing libMisstypeCAPI.so")
if(NOT EXISTS "${MISSTYPE_CAPI_DIR}/libMisstypeCAPI.so")
    message(FATAL_ERROR "Set -DMISSTYPE_CAPI_DIR=<dir containing libMisstypeCAPI.so> (script/linux/build_capi.sh)")
endif()

set(MISSTYPE_DATADIR "${CMAKE_INSTALL_FULL_DATADIR}/misstype")
set(MISSTYPE_CAPI_INSTALL_DIR "${CMAKE_INSTALL_FULL_LIBDIR}/misstype")
set(MISSTYPE_IBUS_EXEC "${CMAKE_INSTALL_FULL_LIBEXECDIR}/ibus-engine-misstype")

add_library(misstype-capi SHARED IMPORTED)
set_target_properties(misstype-capi PROPERTIES
    IMPORTED_LOCATION "${MISSTYPE_CAPI_DIR}/libMisstypeCAPI.so"
    IMPORTED_SONAME "libMisstypeCAPI.so")

add_executable(ibus-engine-misstype src/main.c src/engine.c src/config.c)
target_include_directories(ibus-engine-misstype PRIVATE
    "${MISSTYPE_ROOT}/Sources/CMisstype/include" ${IBUS_INCLUDE_DIRS})
target_compile_definitions(ibus-engine-misstype PRIVATE MISSTYPE_DATADIR="${MISSTYPE_DATADIR}")
target_compile_options(ibus-engine-misstype PRIVATE -Wall -Wextra)
target_link_libraries(ibus-engine-misstype PRIVATE ${IBUS_LIBRARIES} misstype-capi)
set_target_properties(ibus-engine-misstype PROPERTIES
    BUILD_RPATH "${MISSTYPE_CAPI_DIR}"
    INSTALL_RPATH "${MISSTYPE_CAPI_INSTALL_DIR}")

configure_file(data/misstype.xml.in "${CMAKE_BINARY_DIR}/data/misstype.xml" @ONLY)

install(TARGETS ibus-engine-misstype RUNTIME DESTINATION "${CMAKE_INSTALL_LIBEXECDIR}")
install(FILES "${CMAKE_BINARY_DIR}/data/misstype.xml" DESTINATION "${CMAKE_INSTALL_DATADIR}/ibus/component")
install(PROGRAMS "${MISSTYPE_CAPI_DIR}/libMisstypeCAPI.so" DESTINATION "${CMAKE_INSTALL_LIBDIR}/misstype")
install(FILES "${MISSTYPE_ROOT}/Resources/MisstypeIcon.svg"
    DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps" RENAME misstype.svg)

# Headless conformance test against a real ibus-daemon (script/linux/test_ibus.sh).
add_executable(test-misstype-ibus test/test_ibus.c)
target_include_directories(test-misstype-ibus PRIVATE ${IBUS_INCLUDE_DIRS})
target_compile_options(test-misstype-ibus PRIVATE -Wall -Wextra)
target_link_libraries(test-misstype-ibus PRIVATE ${IBUS_LIBRARIES})
