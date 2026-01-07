# Project-level configuration.
cmake_minimum_required(VERSION 3.13)

# CRITICAL: Force system compilers BEFORE project() to prevent Snap toolchain
# CMake caches the compiler after project(), so this must be set before.
set(CMAKE_C_COMPILER "/usr/bin/gcc" CACHE FILEPATH "C compiler" FORCE)
set(CMAKE_CXX_COMPILER "/usr/bin/g++" CACHE FILEPATH "C++ compiler" FORCE)

# Disable Snap's Sysroot to prevent header pollution from snap
set(CMAKE_SYSROOT "")

# System headers and libraries configuration
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -B/usr/lib/x86_64-linux-gnu -B/usr/bin")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -B/usr/lib/x86_64-linux-gnu -B/usr/bin -isystem /usr/include/c++/13 -isystem /usr/include/x86_64-linux-gnu/c++/13 -isystem /usr/include -isystem /usr/include/x86_64-linux-gnu")

# Force system library paths BEFORE Snap paths for linking
# Include fakelibs for symlinks missing in system (e.g., librt.so -> librt.so.1)
set(CMAKE_EXE_LINKER_FLAGS "-Wl,--disable-new-dtags -L/teamspace/studios/this_studio/fakelibs -L/usr/lib/gcc/x86_64-linux-gnu/13 -L/usr/lib/x86_64-linux-gnu -L/lib/x86_64-linux-gnu -Wl,-rpath-link,/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:/snap/flutter/current/usr/lib/x86_64-linux-gnu ${CMAKE_EXE_LINKER_FLAGS}")
set(CMAKE_SHARED_LINKER_FLAGS "-Wl,--disable-new-dtags -L/teamspace/studios/this_studio/fakelibs -L/usr/lib/gcc/x86_64-linux-gnu/13 -L/usr/lib/x86_64-linux-gnu -L/lib/x86_64-linux-gnu -Wl,-rpath-link,/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:/snap/flutter/current/usr/lib/x86_64-linux-gnu ${CMAKE_SHARED_LINKER_FLAGS}")

project(runner LANGUAGES CXX)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib:/usr/lib/x86_64-linux-gnu:/snap/flutter/current/usr/lib/x86_64-linux-gnu")

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "validador_retratos_flutter")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.example.validador_retratos_flutter")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)



# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Wno-sign-compare -Wno-error)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# Application build; see runner/CMakeLists.txt.
link_directories("${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/flutter_webrtc/third_party/libwebrtc/lib/linux-x64")
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# FORCE implicit dependencies to use Snap versions (via our symlinks)
# This overrides System paths for these specific mismatched libraries
target_link_libraries(${BINARY_NAME} PRIVATE 
  "/teamspace/studios/this_studio/fakelibs/libpangoft2-1.0.so.0"
  "/teamspace/studios/this_studio/fakelibs/libatk-bridge-2.0.so.0"
  "/teamspace/studios/this_studio/fakelibs/libatspi.so.0"
)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy missing Snap libraries to the bundle to fix RUNPATH propagation issues in libflutter_linux_gtk.so
install(FILES
  "/snap/flutter/current/usr/lib/x86_64-linux-gnu/libepoxy.so.0"
  "/snap/flutter/current/usr/lib/x86_64-linux-gnu/libepoxy.so.0.0.0"
  "/snap/flutter/current/usr/lib/x86_64-linux-gnu/libgtk-3.so.0"
  "/snap/flutter/current/usr/lib/x86_64-linux-gnu/libgtk-3.so.0.2404.16"
  "/snap/flutter/current/usr/lib/x86_64-linux-gnu/libgdk-3.so.0"
  "/snap/flutter/current/usr/lib/x86_64-linux-gnu/libgdk-3.so.0.2404.16"
  "/usr/lib/x86_64-linux-gnu/librt.so.1"
  "/usr/lib/x86_64-linux-gnu/libgio-2.0.so.0"
  "/usr/lib/x86_64-linux-gnu/libgio-2.0.so.0.8000.0"
  "/usr/lib/x86_64-linux-gnu/libglib-2.0.so.0"
  "/usr/lib/x86_64-linux-gnu/libglib-2.0.so.0.8000.0"
  "/usr/lib/x86_64-linux-gnu/libgmodule-2.0.so.0"
  "/usr/lib/x86_64-linux-gnu/libgmodule-2.0.so.0.8000.0"
  "/usr/lib/x86_64-linux-gnu/libgobject-2.0.so.0"
  "/usr/lib/x86_64-linux-gnu/libgobject-2.0.so.0.8000.0"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
