@echo off
REM ──────────────────────────────────────────────────────────────
REM  dump_tables.bat  –  Extract all needed game data to CSV/files
REM
REM  Requires: poe_data_tools.exe in this folder
REM            (build from https://github.com/LocalIdentity/poe_data_tools)
REM
REM  Usage:
REM    dump_tables.bat                          (auto-detect Steam path)
REM    dump_tables.bat "H:\SteamLibrary"        (custom Steam library root)
REM ──────────────────────────────────────────────────────────────
setlocal

set "SCRIPT_DIR=%~dp0"
set "CSV_DIR=%SCRIPT_DIR%..\data\raw_csv"
set "EXTRACT_DIR=%SCRIPT_DIR%..\data\raw_extracted"
set "PDT=%SCRIPT_DIR%poe_data_tools.exe"

REM Build --steam flag if user provided a Steam path
set "STEAM_FLAG="
if not "%~1"=="" set "STEAM_FLAG=--steam "%~1""

if not exist "%CSV_DIR%" mkdir "%CSV_DIR%"
if not exist "%EXTRACT_DIR%" mkdir "%EXTRACT_DIR%"

echo.
echo === PoE2 Data Extraction ===
echo CSV out:   %CSV_DIR%
echo Files out: %EXTRACT_DIR%
echo.

REM ── Step 1: Dump .datc64 tables to CSV ──
echo [1/2] Dumping .datc64 tables to CSV...
"%PDT%" --patch 2 %STEAM_FLAG% dump-tables "%CSV_DIR%" ^
    "Data/Balance/Stats.datc64" ^
    "Data/Balance/Mods.datc64" ^
    "Data/Balance/ModType.datc64" ^
    "Data/Balance/Words.datc64" ^
    "Data/Balance/MonsterVarieties.datc64" ^
    "Data/Balance/BaseItemTypes.datc64" ^
    "Data/Balance/UniqueGoldPrices.datc64" ^
    "Data/Balance/UniqueStashLayout.datc64" ^
    "Data/Balance/ItemVisualIdentity.datc64"

if errorlevel 1 (
    echo.
    echo ERROR: dump-tables failed.
    exit /b 1
)

REM ── Step 2: Extract CSD files for stat descriptions ──
echo.
echo [2/2] Extracting StatDescriptions CSD files...
"%PDT%" --patch 2 %STEAM_FLAG% extract "%EXTRACT_DIR%" ^
    "Data/StatDescriptions/**/*.csd"

if errorlevel 1 (
    echo.
    echo WARNING: CSD extraction failed. stat_desc_map.tsv will not be updated.
    echo          Other extractors will still work.
)

echo.
echo === Extraction complete! ===
echo.
echo CSV tables: %CSV_DIR%
echo CSD files:  %EXTRACT_DIR%
echo.
echo Run the Python scripts to generate TSV lookup tables:
echo   python extract_stats_dat_csv.py
echo   python extract_mods_dat_csv.py
echo   python extract_monster_names_csv.py
echo   python build_item_names_csv.py
echo   python build_stat_desc_map_csv.py
