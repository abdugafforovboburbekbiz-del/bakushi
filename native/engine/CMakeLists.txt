cmake_minimum_required(VERSION 3.14)
project(bakushi_engine LANGUAGES C)

add_library(bakushi_engine SHARED
  "bakushi_engine.c"
)

target_include_directories(bakushi_engine PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_definitions(bakushi_engine PRIVATE BA_BUILD)

# miniaudio WASAPI backend requires COM.
target_link_libraries(bakushi_engine PRIVATE ole32)

set_target_properties(bakushi_engine PROPERTIES
  PREFIX ""
  C_STANDARD 99
  C_STANDARD_REQUIRED ON
)
