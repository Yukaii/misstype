cmake_minimum_required(VERSION 3.16)
# The project name sets CMAKE_INSTALL_DOCDIR (share/doc/mistype).
project(mistype VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(GNUInstallDirs)
find_package(Fcitx5Core REQUIRED)
find_package(Fcitx5Utils REQUIRED)

get_filename_component(MISTYPE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

# Directory holding libMistypeCAPI.so (built by script/linux/build_capi.sh).
set(MISTYPE_CAPI_DIR "" CACHE PATH "Directory containing libMistypeCAPI.so")
if(NOT EXISTS "${MISTYPE_CAPI_DIR}/libMistypeCAPI.so")
    message(FATAL_ERROR "Set -DMISTYPE_CAPI_DIR=<dir containing libMistypeCAPI.so> (script/linux/build_capi.sh)")
endif()
# Resources installed by `cmake --install` (script/prepare_lexicon.py output).
set(MISTYPE_LEXICON_DIR "${MISTYPE_ROOT}/.cache/mcbopomofo" CACHE PATH "Directory with lexicon.tsv and toneless.tsv")

set(MISTYPE_DATADIR "${CMAKE_INSTALL_FULL_DATADIR}/mistype")
set(MISTYPE_CAPI_INSTALL_DIR "${CMAKE_INSTALL_FULL_LIBDIR}/mistype")

add_library(mistype-capi SHARED IMPORTED)
set_target_properties(mistype-capi PROPERTIES
    IMPORTED_LOCATION "${MISTYPE_CAPI_DIR}/libMistypeCAPI.so"
    IMPORTED_SONAME "libMistypeCAPI.so")

# The addon: libmistype-fcitx5.so
add_library(mistype-fcitx5 MODULE src/engine.cpp)
target_include_directories(mistype-fcitx5 PRIVATE "${MISTYPE_ROOT}/Sources/CMistype/include")
target_compile_definitions(mistype-fcitx5 PRIVATE MISTYPE_DATADIR="${MISTYPE_DATADIR}")
target_link_libraries(mistype-fcitx5 PRIVATE Fcitx5::Core Fcitx5::Utils mistype-capi)
set_target_properties(mistype-fcitx5 PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/src"
    BUILD_RPATH "${MISTYPE_CAPI_DIR}"
    INSTALL_RPATH "${MISTYPE_CAPI_INSTALL_DIR}")

# Addon and input-method configs, laid out like fcitx5's data dir so the
# headless tests can point setupTestingEnvironment at build/data.
configure_file(data/addon/mistype.conf.in "${CMAKE_BINARY_DIR}/data/addon/mistype.conf" @ONLY)
configure_file(data/inputmethod/mistype.conf "${CMAKE_BINARY_DIR}/data/inputmethod/mistype.conf" COPYONLY)

install(TARGETS mistype-fcitx5 LIBRARY DESTINATION "${FCITX_INSTALL_ADDONDIR}")
install(PROGRAMS "${MISTYPE_CAPI_DIR}/libMistypeCAPI.so" DESTINATION "${CMAKE_INSTALL_LIBDIR}/mistype")
install(FILES "${CMAKE_BINARY_DIR}/data/addon/mistype.conf" DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")
install(FILES "${CMAKE_BINARY_DIR}/data/inputmethod/mistype.conf" DESTINATION "${FCITX_INSTALL_PKGDATADIR}/inputmethod")
install(FILES
    "${MISTYPE_LEXICON_DIR}/lexicon.tsv"
    "${MISTYPE_LEXICON_DIR}/toneless.tsv"
    "${MISTYPE_ROOT}/Resources/local_phrases.tsv"
    DESTINATION "${CMAKE_INSTALL_DATADIR}/mistype")
install(FILES "${MISTYPE_ROOT}/LICENSE" "${MISTYPE_ROOT}/THIRD_PARTY_NOTICES.md" DESTINATION "${CMAKE_INSTALL_DOCDIR}")
install(DIRECTORY "${MISTYPE_ROOT}/third_party/" DESTINATION "${CMAKE_INSTALL_DOCDIR}/third_party")

# Headless conformance tests (docs/cross-platform.md C1-C12 + delivery rules).
find_package(Fcitx5ModuleTestFrontend REQUIRED)
enable_testing()
add_executable(testmistype test/testmistype.cpp)
target_link_libraries(testmistype PRIVATE Fcitx5::Core Fcitx5::Utils Fcitx5::Module::TestFrontend)
target_compile_definitions(testmistype PRIVATE
    TESTING_BINARY_DIR="${CMAKE_BINARY_DIR}"
    FCITX_TESTING_ADDONDIR="${FCITX_INSTALL_ADDONDIR}"
    FCITX_TESTING_DATADIR="${FCITX_INSTALL_PKGDATADIR}/testing")
add_dependencies(testmistype mistype-fcitx5)
add_test(NAME testmistype COMMAND testmistype)
# Pass/fail is the exit code: a failed FCITX_ASSERT or a wrong commit aborts.
set_tests_properties(testmistype PROPERTIES
    ENVIRONMENT "MISTYPE_RESOURCES=${MISTYPE_ROOT}/tests/fixtures/lexicon;XDG_DATA_HOME=${CMAKE_BINARY_DIR}/xdg-data")
