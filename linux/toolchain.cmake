# Force the use of system GCC toolchain
set(CMAKE_C_COMPILER "/usr/bin/gcc-13")
set(CMAKE_CXX_COMPILER "/usr/bin/g++-13")

# Ignore the sysroot from Flutter snap
set(CMAKE_SYSROOT "")
set(CMAKE_FIND_ROOT_PATH "")

# Use system standard libraries
set(CMAKE_CXX_STANDARD_INCLUDE_DIRECTORIES "/usr/include/c++/13;/usr/include/x86_64-linux-gnu/c++/13;/usr/include/c++/13/backward;/usr/include/x86_64-linux-gnu;/usr/include")
