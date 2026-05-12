cmake_minimum_required(VERSION 3.20)
project(PoE2DX11Overlay LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(IMGUI_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/imgui" CACHE PATH "Path to dear imgui root")
set(MINHOOK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/minhook" CACHE PATH "Path to minhook root")

set(IMGUI_SOURCES
    ${IMGUI_DIR}/imgui.cpp
    ${IMGUI_DIR}/imgui_draw.cpp
    ${IMGUI_DIR}/imgui_tables.cpp
    ${IMGUI_DIR}/imgui_widgets.cpp
    ${IMGUI_DIR}/backends/imgui_impl_dx11.cpp
    ${IMGUI_DIR}/backends/imgui_impl_win32.cpp
)

set(MINHOOK_SOURCES
    ${MINHOOK_DIR}/src/buffer.c
    ${MINHOOK_DIR}/src/hook.c
    ${MINHOOK_DIR}/src/trampoline.c
    ${MINHOOK_DIR}/src/hde/hde64.c
)

foreach(f IN LISTS IMGUI_SOURCES MINHOOK_SOURCES)
    if(NOT EXISTS "${f}")
        message(FATAL_ERROR "Missing dependency source: ${f}. Check IMGUI_DIR/MINHOOK_DIR.")
    endif()
endforeach()

add_library(PoE2DX11Overlay SHARED
    DX11OverlayHook.cpp
    RenderQueueClient.cpp
    ${IMGUI_SOURCES}
    ${MINHOOK_SOURCES}
)

target_include_directories(PoE2DX11Overlay PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${IMGUI_DIR}
    ${IMGUI_DIR}/backends
    ${MINHOOK_DIR}/include
    ${MINHOOK_DIR}/src
)

target_compile_definitions(PoE2DX11Overlay PRIVATE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
)

target_link_libraries(PoE2DX11Overlay PRIVATE
    d3d11
    dxgi
    user32
)
