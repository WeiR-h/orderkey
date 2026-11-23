@echo off
setlocal
pushd "%~dp0" || exit /b 2
set "OUT=%~1"
if not defined OUT set "OUT=segmented-replay"
set "CASE=examples\earthquakes"
set "LATE=%CASE%\late"
mkdir "%OUT%" || goto failed
call "%~dp0replay-gate.cmd" "%OUT%\baseline" || goto failed
set /p "APPROVED="<"%CASE%\approved.sha256"
orderkey.exe explain --where "%LATE%\where.json" --source-contract "%LATE%\source.json" --target-contract "%LATE%\target.json" > "%OUT%\diagnosis.json" || goto failed
orderkey.exe gate-selected --selection "%OUT%\baseline\selection" --selection-sha256 "%APPROVED%" --batches "%CASE%\late.json" --delivery "%OUT%\baseline\delivery" --scan-mode segmented --out "%OUT%\repaired" || goto failed
orderkey.exe build --input "%LATE%\input.jsonl" --source-contract "%LATE%\source.json" --target-contract "%LATE%\target.json" --out "%OUT%\late-index" > "%OUT%\build.stdout" || goto failed
orderkey.exe check-queries --out "%OUT%\late-index" --queries "%LATE%\layout-workload.json" --scan-mode segmented --report "%OUT%\measured.json" > "%OUT%\check.stdout" || goto failed
orderkey.exe query --out "%OUT%\late-index" --where "%LATE%\where.json" --scan-mode segmented --limit 50 > "%OUT%\read.json" || goto failed
echo Segmented replay complete. Reports in "%OUT%"
popd
exit /b 0

:failed
popd
exit /b 2
