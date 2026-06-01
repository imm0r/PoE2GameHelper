cmake_minimum_required(VERSION 3.20)
project(DX11OverlayTestHost LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(DX11OverlayTestHost DX11OverlayTestHost.cpp)
target_link_libraries(DX11OverlayTestHost PRIVATE d3d11 dxgi user32)
