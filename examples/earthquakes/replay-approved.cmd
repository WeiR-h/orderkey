@echo off
setlocal
pushd "%~dp0" || exit /b 2
set "OUT=%~1"
if not defined OUT set "OUT=approved-replay"
set "FIXTURE=examples\earthquakes"
set "TRAIN=%FIXTURE%\training"
mkdir "%OUT%" || goto failed
set /p "APPROVED="<"%FIXTURE%\approved.sha256"
orderkey.exe compare-layouts --input "%TRAIN%\input.jsonl" --source-contract "%TRAIN%\source.json" --queries "%TRAIN%\layout-workload.json" --candidate "%TRAIN%\target.json" --out "%OUT%\selection" > "%OUT%\comparison.stdout" || goto failed
for %%B in (late near) do (
    orderkey.exe build --input "%FIXTURE%\%%B\input.jsonl" --source-contract "%FIXTURE%\%%B\source.json" --target-contract "%OUT%\selection\target.contract" --out "%OUT%\%%B-index" > "%OUT%\%%B-build.stdout" || goto failed
)
call :gate single
if not "%ERRORLEVEL%"=="1" goto failed
echo Single range rejected. See "%OUT%\single\batch-receipt.json"
call :gate segmented || goto failed
echo Segmented scan approved. See "%OUT%\segmented\batch-receipt.json"
set "ORDERKEY_REPLAY_RECEIPT=%OUT%\segmented\batch-receipt.json"
powershell -NoLogo -NoProfile -NonInteractive -Command "$sha=[Security.Cryptography.SHA256]::Create(); try { [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($env:ORDERKEY_REPLAY_RECEIPT))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }" > "%OUT%\receipt.sha256" || goto failed
set /p "TRUSTED="<"%OUT%\receipt.sha256"
approved-consumer.exe "%OUT%\late-index" "%ORDERKEY_REPLAY_RECEIPT%" "%TRUSTED%" > "%OUT%\consumer.json" || goto failed
approved-consumer.exe "%OUT%\near-index" "%ORDERKEY_REPLAY_RECEIPT%" "%TRUSTED%" > "%OUT%\wrong.stdout" 2> "%OUT%\wrong.stderr"
if not errorlevel 1 goto failed
findstr /l /c:"snapshot manifest differs from batch receipt" "%OUT%\wrong.stderr" >nul || goto failed
echo Approved 33-row read passed. Wrong snapshot rejected. Reports in "%OUT%"
popd
exit /b 0

:gate
orderkey.exe gate-batch --selection "%OUT%\selection" --selection-sha256 "%APPROVED%" --batches "%FIXTURE%\late.json" --batch-id late --delivery "%OUT%\late-index" --scan-mode "%~1" --out "%OUT%\%~1" > "%OUT%\%~1.stdout"
exit /b %ERRORLEVEL%

:failed
popd
exit /b 2
