cmake_minimum_required(VERSION 3.20)
project(PoE2DX11Overlay LANGUAGES CXX)

add_library(PoE2DX11Overlay SHARED
    DX11OverlayHook.cpp
    RenderQueueClient.cpp
)

target_compile_features(PoE2DX11Overlay PRIVATE cxx_std_17)

target_include_directories(PoE2DX11Overlay PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(PoE2DX11Overlay PRIVATE
    d3d11
)
