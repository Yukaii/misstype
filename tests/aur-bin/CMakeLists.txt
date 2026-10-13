cmake_minimum_required(VERSION 3.16)
project(misstype_binary_conformance LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
find_package(Fcitx5Core REQUIRED)
find_package(Fcitx5Utils REQUIRED)
find_package(Fcitx5ModuleTestFrontend REQUIRED)
get_filename_component(DEFAULT_MISSTYPE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(MISSTYPE_ROOT "${DEFAULT_MISSTYPE_ROOT}" CACHE PATH "Release source tree for the installed binary's test driver")
# Build only the driver. The addon and core are the installed release binaries.
add_executable(testmisstype "${MISSTYPE_ROOT}/linux/fcitx5/test/testmisstype.cpp")
target_link_libraries(testmisstype PRIVATE Fcitx5::Core Fcitx5::Utils Fcitx5::Module::TestFrontend)
target_compile_definitions(testmisstype PRIVATE
    TESTING_BINARY_DIR="${CMAKE_BINARY_DIR}"
    FCITX_TESTING_ADDONDIR="${FCITX_INSTALL_ADDONDIR}"
    FCITX_TESTING_DATADIR="${FCITX_INSTALL_PKGDATADIR}/testing")
file(CREATE_LINK "${FCITX_INSTALL_PKGDATADIR}" "${CMAKE_BINARY_DIR}/data" SYMBOLIC)
