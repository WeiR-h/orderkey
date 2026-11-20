@echo off
setlocal
pushd "%~dp0" || exit /b 2
set "OUT=%~1"
if not defined OUT set "OUT=gate-replay"
set "CASE=examples\earthquakes"
set "TRAIN=%CASE%\training"
mkdir "%OUT%" || goto failed
set /p "APPROVED="<"%CASE%\approved.sha256"
orderkey.exe compare-layouts --input "%TRAIN%\input.jsonl" --source-contract "%TRAIN%\source.json" --queries "%TRAIN%\layout-workload.json" --candidate "%TRAIN%\target.json" --out "%OUT%\selection" > "%OUT%\comparison.stdout" || goto failed
orderkey.exe build-selected --input "%TRAIN%\input.jsonl" --source-contract "%TRAIN%\source.json" --queries "%TRAIN%\layout-workload.json" --selection "%OUT%\selection" --out "%OUT%\delivery" > "%OUT%\build.stdout" || goto failed
orderkey.exe gate-selected --selection "%OUT%\selection" --selection-sha256 "%APPROVED%" --batches "%CASE%\near.json" --delivery "%OUT%\delivery" --out "%OUT%\near" || goto failed
orderkey.exe gate-selected --selection "%OUT%\selection" --selection-sha256 "%APPROVED%" --batches "%CASE%\late.json" --delivery "%OUT%\delivery" --out "%OUT%\late"
if not "%errorlevel%"=="1" goto failed
orderkey.exe verify-delivery --out "%OUT%\delivery" --selection-sha256 "%APPROVED%" > "%OUT%\delivery-open.json" || goto failed
echo Replay complete. Reports in "%OUT%"
popd
exit /b 0

:failed
popd
exit /b 2
