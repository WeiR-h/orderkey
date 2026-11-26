@echo off
setlocal
pushd "%~dp0" || exit /b 2
set "OUT=%~1"
if not defined OUT set "OUT=bounded-selection-replay"
set "FIXTURE=examples\bounded-selection"
set "TRAIN=%FIXTURE%\training"
set "LATE=%FIXTURE%\late"
mkdir "%OUT%" || goto failed
orderkey.exe compare-layouts --input "%TRAIN%\input.jsonl" --source-contract "%TRAIN%\source.json" --queries "%TRAIN%\workload-4.json" --candidate "%TRAIN%\target.json" --out "%OUT%\legacy" > "%OUT%\legacy.stdout" || goto failed
for %%N in (3 4) do (
    orderkey.exe compare-layouts --input "%TRAIN%\input.jsonl" --source-contract "%TRAIN%\source.json" --queries "%TRAIN%\workload-%%N.json" --candidate "%TRAIN%\target.json" --scan-mode bounded --out "%OUT%\selection-%%N" > "%OUT%\selection-%%N.stdout" || goto failed
)
echo Compared the same layouts using the single range and both dual budgets.

set "ORDERKEY_REPLAY_TRAIN=%TRAIN%"
set "ORDERKEY_REPLAY_OUT=%OUT%"
powershell -NoLogo -NoProfile -NonInteractive -Command "$ErrorActionPreference='Stop'; $train=$env:ORDERKEY_REPLAY_TRAIN; $out=$env:ORDERKEY_REPLAY_OUT; $flags=@('build-selected','--input',(Join-Path $train 'input.jsonl'),'--source-contract',(Join-Path $train 'source.json'),'--queries',(Join-Path $train 'workload-4.json'),'--selection',(Join-Path $out 'selection-4'),'--out',(Join-Path $out 'training-index'),'--pause-after','selected-workload'); $arguments=($flags | ForEach-Object { [char]34 + $_ + [char]34 }) -join ' '; $log=Join-Path $out 'interruption.stdout'; $child=Start-Process -FilePath (Join-Path (Get-Location).Path 'orderkey.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError (Join-Path $out 'interruption.stderr'); try { for ($i=0; $i -lt 300; $i++) { if ($child.HasExited) { throw 'Training build exited before checkpoint' }; if ((Get-Content -LiteralPath $log -Raw) -match 'paused selected-workload') { exit 0 }; Start-Sleep -Milliseconds 100 }; throw 'Training build did not reach checkpoint' } finally { if (!$child.HasExited) { Stop-Process -InputObject $child -Force }; $child.WaitForExit() }" || goto failed
set /p "APPROVED="<"%FIXTURE%\approved-4.sha256"
orderkey.exe verify-delivery --out "%OUT%\training-index" --selection-sha256 "%APPROVED%" > "%OUT%\incomplete.stdout"
if not errorlevel 1 goto failed
orderkey.exe build-selected --input "%TRAIN%\input.jsonl" --source-contract "%TRAIN%\source.json" --queries "%TRAIN%\workload-4.json" --selection "%OUT%\selection-4" --out "%OUT%\training-index" --resume > "%OUT%\resume.stdout" || goto failed
orderkey.exe verify-delivery --out "%OUT%\training-index" --selection-sha256 "%APPROVED%" > "%OUT%\training-ready.json" || goto failed
echo Terminated the training build before workload verification, rejected it, then resumed it.

orderkey.exe build --input "%LATE%\input.jsonl" --source-contract "%LATE%\source.json" --target-contract "%OUT%\selection-4\target.contract" --out "%OUT%\late-index" > "%OUT%\build.stdout" || goto failed
call :gate 3 cap-3
if not "%ERRORLEVEL%"=="1" goto failed
call :gate 4 cap-4 || goto failed
call :gate 4 other-approval || goto failed
call :hash cap-4 receipt || goto failed
call :hash other-approval other || goto failed
set /p "TRUSTED="<"%OUT%\receipt.sha256"
set /p "OTHER="<"%OUT%\other.sha256"
approved-consumer.exe "%OUT%\late-index" "%OUT%\cap-4\batch-receipt.json" "%TRUSTED%" bounded "%OUT%\other-approval\batch-receipt.json" "%OTHER%" > "%OUT%\consumer.json" || goto failed
echo Late batch rejected at 3 ranges and approved at 4 ranges. Read 593 rows. Reports in "%OUT%"
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
