cmake_minimum_required(VERSION 3.16)
# The project name sets CMAKE_INSTALL_DOCDIR (share/doc/misstype).
project(misstype VERSION 0.1 LANGUAGES C CXX)

# Newer fcitx5 headers use std::source_location (C++20).
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(GNUInstallDirs)
find_package(Fcitx5Core REQUIRED)
find_package(Fcitx5Config REQUIRED)
find_package(Fcitx5Utils REQUIRED)

get_filename_component(MISSTYPE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

# Directory holding libMisstypeCAPI.so (built by script/linux/build_capi.sh).
set(MISSTYPE_CAPI_DIR "" CACHE PATH "Directory containing libMisstypeCAPI.so")
if(NOT EXISTS "${MISSTYPE_CAPI_DIR}/libMisstypeCAPI.so")
    message(FATAL_ERROR "Set -DMISSTYPE_CAPI_DIR=<dir containing libMisstypeCAPI.so> (script/linux/build_capi.sh)")
endif()
# Resources installed by `cmake --install` (script/prepare_lexicon.py output).
set(MISSTYPE_LEXICON_DIR "${MISSTYPE_ROOT}/.cache/mcbopomofo" CACHE PATH "Directory with lexicon.tsv and toneless.tsv")

set(MISSTYPE_DATADIR "${CMAKE_INSTALL_FULL_DATADIR}/misstype")
set(MISSTYPE_CAPI_INSTALL_DIR "${CMAKE_INSTALL_FULL_LIBDIR}/misstype")

add_library(misstype-capi SHARED IMPORTED)
set_target_properties(misstype-capi PROPERTIES
    IMPORTED_LOCATION "${MISSTYPE_CAPI_DIR}/libMisstypeCAPI.so"
    IMPORTED_SONAME "libMisstypeCAPI.so")

# The addon: libmisstype-fcitx5.so
add_library(misstype-fcitx5 MODULE src/engine.cpp)
target_include_directories(misstype-fcitx5 PRIVATE "${MISSTYPE_ROOT}/Sources/CMisstype/include")
target_compile_definitions(misstype-fcitx5 PRIVATE MISSTYPE_DATADIR="${MISSTYPE_DATADIR}")
target_link_libraries(misstype-fcitx5 PRIVATE Fcitx5::Core Fcitx5::Config Fcitx5::Utils misstype-capi)
set_target_properties(misstype-fcitx5 PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/src"
    BUILD_RPATH "${MISSTYPE_CAPI_DIR}"
    INSTALL_RPATH "${MISSTYPE_CAPI_INSTALL_DIR}")

# Addon and input-method configs, laid out like fcitx5's data dir so the
# headless tests can point setupTestingEnvironment at build/data.
configure_file(data/addon/misstype.conf.in "${CMAKE_BINARY_DIR}/data/addon/misstype.conf" @ONLY)
configure_file(data/inputmethod/misstype.conf "${CMAKE_BINARY_DIR}/data/inputmethod/misstype.conf" COPYONLY)

install(TARGETS misstype-fcitx5 LIBRARY DESTINATION "${FCITX_INSTALL_ADDONDIR}")
install(PROGRAMS "${MISSTYPE_CAPI_DIR}/libMisstypeCAPI.so" DESTINATION "${CMAKE_INSTALL_LIBDIR}/misstype")
install(FILES "${CMAKE_BINARY_DIR}/data/addon/misstype.conf" DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")
install(FILES "${CMAKE_BINARY_DIR}/data/inputmethod/misstype.conf" DESTINATION "${FCITX_INSTALL_PKGDATADIR}/inputmethod")
# Tray/IM icon (Icon= in inputmethod/misstype.conf) and the app icon shared with macOS.
install(FILES data/icons/misstype-symbolic.svg DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor/symbolic/apps")
install(FILES "${MISSTYPE_ROOT}/Resources/MisstypeIcon.svg" DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps" RENAME misstype.svg)
install(FILES
    "${MISSTYPE_LEXICON_DIR}/lexicon.tsv"
    "${MISSTYPE_LEXICON_DIR}/toneless.tsv"
    "${MISSTYPE_ROOT}/Resources/local_phrases.tsv"
    DESTINATION "${CMAKE_INSTALL_DATADIR}/misstype")
# Optional English word list (mixed typing); absent = feature off. CC BY-SA, see THIRD_PARTY_NOTICES.md.
if(EXISTS "${MISSTYPE_ROOT}/.cache/frequencywords/english.tsv")
    install(FILES "${MISSTYPE_ROOT}/.cache/frequencywords/english.tsv" DESTINATION "${CMAKE_INSTALL_DATADIR}/misstype")
endif()
install(FILES "${MISSTYPE_ROOT}/LICENSE" "${MISSTYPE_ROOT}/THIRD_PARTY_NOTICES.md" DESTINATION "${CMAKE_INSTALL_DOCDIR}")
install(DIRECTORY "${MISSTYPE_ROOT}/third_party/" DESTINATION "${CMAKE_INSTALL_DOCDIR}/third_party")

# misstypectl (settings + dictionary CLI, Swift: script/linux/build_capi.sh builds it)
# and the GTK4 dictionary editor on top of it. Both are optional: the IME
# itself needs neither.
if(EXISTS "${MISSTYPE_CAPI_DIR}/misstypectl")
    install(PROGRAMS "${MISSTYPE_CAPI_DIR}/misstypectl" DESTINATION "${CMAKE_INSTALL_BINDIR}")
endif()
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
    pkg_check_modules(GTK4 QUIET IMPORTED_TARGET gtk4)
endif()
if(GTK4_FOUND)
    add_executable(misstype-dictionary-editor tools/dictionary-editor.c)
    target_compile_options(misstype-dictionary-editor PRIVATE -Wall -Wextra)
    target_link_libraries(misstype-dictionary-editor PRIVATE PkgConfig::GTK4)
    install(TARGETS misstype-dictionary-editor RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")
    install(FILES data/misstype-dictionary-editor.desktop DESTINATION "${CMAKE_INSTALL_DATADIR}/applications")
else()
    message(STATUS "GTK4 not found: misstype-dictionary-editor not built (misstypectl dict edit still works)")
endif()

# Headless conformance tests (docs/cross-platform.md C1-C13 + delivery rules).
find_package(Fcitx5ModuleTestFrontend REQUIRED)
enable_testing()
add_executable(testmisstype test/testmisstype.cpp)
target_link_libraries(testmisstype PRIVATE Fcitx5::Core Fcitx5::Utils Fcitx5::Module::TestFrontend)
target_compile_definitions(testmisstype PRIVATE
    TESTING_BINARY_DIR="${CMAKE_BINARY_DIR}"
    FCITX_TESTING_ADDONDIR="${FCITX_INSTALL_ADDONDIR}"
    FCITX_TESTING_DATADIR="${FCITX_INSTALL_PKGDATADIR}/testing")
add_dependencies(testmisstype misstype-fcitx5)
add_test(NAME testmisstype COMMAND testmisstype)
# Pass/fail is the exit code: a failed FCITX_ASSERT or a wrong commit aborts.
set_tests_properties(testmisstype PROPERTIES
    ENVIRONMENT "MISSTYPE_RESOURCES=${MISSTYPE_ROOT}/tests/fixtures/lexicon;XDG_DATA_HOME=${CMAKE_BINARY_DIR}/xdg-data")
