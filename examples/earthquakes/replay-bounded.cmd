@echo off
setlocal
pushd "%~dp0" || exit /b 2
set "OUT=%~1"
if not defined OUT set "OUT=bounded-replay"
set "FIXTURE=examples\bounded"
set "TRAIN=%FIXTURE%\training"
set "LATE=%FIXTURE%\late"
mkdir "%OUT%" || goto failed
for %%N in (3 4) do (
    orderkey.exe compare-layouts --input "%TRAIN%\input.jsonl" --source-contract "%TRAIN%\source.json" --queries "%TRAIN%\workload-%%N.json" --candidate "%TRAIN%\target.json" --out "%OUT%\selection-%%N" > "%OUT%\selection-%%N.stdout" || goto failed
)
orderkey.exe build --input "%LATE%\input.jsonl" --source-contract "%LATE%\source.json" --target-contract "%OUT%\selection-4\target.contract" --out "%OUT%\late-index" > "%OUT%\build.stdout" || goto failed
call :gate 3 cap-3
if not "%ERRORLEVEL%"=="1" goto failed
echo Three-window plan rejected. See "%OUT%\cap-3\batch-receipt.json"
call :gate 4 cap-4 || goto failed
call :gate 4 other-approval || goto failed
call :hash cap-4 receipt || goto failed
call :hash other-approval other || goto failed
set /p "TRUSTED="<"%OUT%\receipt.sha256"
set /p "OTHER="<"%OUT%\other.sha256"
approved-consumer.exe "%OUT%\late-index" "%OUT%\cap-4\batch-receipt.json" "%TRUSTED%" bounded "%OUT%\other-approval\batch-receipt.json" "%OTHER%" > "%OUT%\consumer.json" || goto failed
echo Four-window plan approved. Read 593 rows and rejected a cross-receipt cursor. Reports in "%OUT%"
popd
exit /b 0

:gate
set /p "APPROVED="<"%FIXTURE%\approved-%~1.sha256"
orderkey.exe gate-batch --selection "%OUT%\selection-%~1" --selection-sha256 "%APPROVED%" --batches "%FIXTURE%\batches-%~1.json" --batch-id late --delivery "%OUT%\late-index" --scan-mode bounded --out "%OUT%\%~2" > "%OUT%\%~2.stdout"
exit /b %ERRORLEVEL%

:hash
set "ORDERKEY_REPLAY_RECEIPT=%OUT%\%~1\batch-receipt.json"
powershell -NoLogo -NoProfile -NonInteractive -Command "$sha=[Security.Cryptography.SHA256]::Create(); try { [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($env:ORDERKEY_REPLAY_RECEIPT))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }" > "%OUT%\%~2.sha256"
exit /b %ERRORLEVEL%

:failed
popd
exit /b 2
