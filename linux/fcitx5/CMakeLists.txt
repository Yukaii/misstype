cmake_minimum_required(VERSION 3.16)
project(mistype VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Required fcitx5 components
find_package(Fcitx5Core REQUIRED)
find_package(Fcitx5Config REQUIRED)
find_package(Fcitx5Utils REQUIRED)
find_package(Fcitx5ModuleTestFrontend REQUIRED)

# Cache variable for CAPI library directory
set(MISTYPE_CAPI_DIR "" CACHE PATH "Directory containing libMistypeCAPI.so")
if(NOT MISTYPE_CAPI_DIR)
    message(FATAL_ERROR "MISTYPE_CAPI_DIR not set. Pass -DMISTYPE_CAPI_DIR=/path/to/libMistypeCAPI.so")
endif()

# Include path for C ABI header
include_directories(${CMAKE_SOURCE_DIR}/../../Sources/CMistype/include)

# Addon target
add_library(mistype-fcitx5 SHARED src/engine.cpp)
target_link_libraries(mistype-fcitx5 PRIVATE
    Fcitx5::Core
    Fcitx5::Config
    Fcitx5::Utils
    ${MISTYPE_CAPI_DIR}/libMistypeCAPI.so
)
target_compile_definitions(mistype-fcitx5 PRIVATE MISTYPE_DATADIR="${MISTYPE_DATADIR}")
set_target_properties(mistype-fcitx5 PROPERTIES
    OUTPUT_NAME "mistype-fcitx5"
    PREFIX ""
    SUFFIX ".so"
    BUILD_RPATH ${MISTYPE_CAPI_DIR}
)

# Data directory for lexicon files
set(MISTYPE_DATADIR "${CMAKE_INSTALL_FULL_DATADIR}/mistype" CACHE PATH "Install directory for lexicon files")

# Configure addon config
configure_file(data/addon/mistype.conf.in ${CMAKE_BINARY_DIR}/data/addon/mistype.conf @ONLY)

# Install rules
install(TARGETS mistype-fcitx5
    LIBRARY DESTINATION ${FCITX_INSTALL_ADDONDIR}
)
install(FILES ${CMAKE_BINARY_DIR}/data/addon/mistype.conf
    DESTINATION ${FCITX_INSTALL_ADDONDIR}
)
install(FILES data/inputmethod/mistype.conf
    DESTINATION ${FCITX_INSTALL_PKGDATADIR}/inputmethod
)

# Create staging directory for install files
add_custom_command(TARGET mistype-fcitx5 POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_BINARY_DIR}/install-stage/share/mistype
    COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_BINARY_DIR}/install-stage/share/doc/mistype/third_party
    COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_BINARY_DIR}/install-stage/lib/mistype
    COMMAND ${CMAKE_COMMAND} -E copy
        /w/.cache/mcbopomofo/lexicon.tsv
        /w/.cache/mcbopomofo/toneless.tsv
        ${CMAKE_BINARY_DIR}/install-stage/share/mistype/
    COMMAND ${CMAKE_COMMAND} -E copy
        /w/Resources/local_phrases.tsv
        ${CMAKE_BINARY_DIR}/install-stage/share/mistype/
    COMMAND ${CMAKE_COMMAND} -E copy
        /w/LICENSE
        /w/THIRD_PARTY_NOTICES.md
        ${CMAKE_BINARY_DIR}/install-stage/share/doc/mistype/
    COMMAND ${CMAKE_COMMAND} -E copy
        /w/.build/aarch64-unknown-linux-gnu/release/libMistypeCAPI.so
        ${CMAKE_BINARY_DIR}/install-stage/lib/mistype/
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        /w/third_party/
        ${CMAKE_BINARY_DIR}/install-stage/share/doc/mistype/third_party/
    COMMENT "Staging files for installation"
)

# Install staged files
install(DIRECTORY ${CMAKE_BINARY_DIR}/install-stage/share/
    DESTINATION share
)
install(DIRECTORY ${CMAKE_BINARY_DIR}/install-stage/share/doc/
    DESTINATION share/doc
)
install(DIRECTORY ${CMAKE_BINARY_DIR}/install-stage/lib/
    DESTINATION lib/aarch64-linux-gnu
)

# Test target - skip for now, verify addon loads via ctest
# if(Fcitx5ModuleTestFrontend_FOUND)
#     add_executable(testmistype test/testmistype.cpp)
#     target_link_libraries(testmistype PRIVATE
#         Fcitx5::Core
#         Fcitx5::Utils
#         Fcitx5::Module::TestFrontend
#         mistype-fcitx5
#     )
#     target_include_directories(testmistype PRIVATE ${CMAKE_SOURCE_DIR}/src)
#     add_test(NAME mistype-fcitx5-test COMMAND testmistype)
# endif()