@echo off
setlocal
pushd "%~dp0" || exit /b 2
set "OUT=%~1"
if not defined OUT set "OUT=batch-selection-replay"
set "FIXTURE=examples\batch-selection"
set "INPUTS=%OUT%\inputs"
set "TRAIN=%INPUTS%\training"
mkdir "%OUT%" || goto failed
mkdir "%TRAIN%" || goto failed
mkdir "%INPUTS%\middle" || goto failed
copy "%FIXTURE%\training\*" "%TRAIN%\" >nul || goto failed
copy "%FIXTURE%\middle\input.jsonl" "%INPUTS%\middle\input.jsonl" >nul || goto failed
for %%N in (3 4) do (
    copy "%FIXTURE%\assessment-%%N.json" "%INPUTS%\assessment-%%N.json" >nul || goto failed
)
orderkey.exe compare-layouts --input "%TRAIN%\input.jsonl" --source-contract "%TRAIN%\source.json" --queries "%TRAIN%\workload-4.json" --candidate "%TRAIN%\target.json" --scan-mode bounded --out "%OUT%\first-week" > "%OUT%\first-week.stdout" || goto failed
for %%N in (3 4) do (
    orderkey.exe compare-batches --batches "%INPUTS%\assessment-%%N.json" --anchor middle --candidate "%TRAIN%\target.json" --out "%OUT%\selection-%%N" > "%OUT%\selection-%%N.stdout" || goto failed
)
echo Compared one week and two assessed batches. The third-week export is still withheld.

set /p "ORDERKEY_REPLAY_ASSESSMENT="<"%FIXTURE%\approved-assessment-4.sha256"
set /p "APPROVED="<"%FIXTURE%\approved-selection-4.sha256"
set "ORDERKEY_REPLAY_OUT=%OUT%"
powershell -NoLogo -NoProfile -NonInteractive -Command "$ErrorActionPreference='Stop'; $out=$env:ORDERKEY_REPLAY_OUT; $inputs=Join-Path $out 'inputs'; $train=Join-Path $inputs 'training'; $flags=@('build-selected','--input',(Join-Path $inputs 'middle\input.jsonl'),'--source-contract',(Join-Path $train 'source.json'),'--queries',(Join-Path $train 'workload-4.json'),'--selection',(Join-Path $out 'selection-4'),'--assessment-batches',(Join-Path $inputs 'assessment-4.json'),'--assessment-sha256',$env:ORDERKEY_REPLAY_ASSESSMENT,'--out',(Join-Path $out 'anchor-index'),'--pause-after','selected-workload'); $arguments=($flags | ForEach-Object { [char]34 + $_ + [char]34 }) -join ' '; $log=Join-Path $out 'interruption.stdout'; $child=Start-Process -FilePath (Join-Path (Get-Location).Path 'orderkey.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError (Join-Path $out 'interruption.stderr'); try { for ($i=0; $i -lt 300; $i++) { if ($child.HasExited) { throw 'Anchor build exited before checkpoint' }; if ((Get-Content -LiteralPath $log -Raw) -match 'paused selected-workload') { exit 0 }; Start-Sleep -Milliseconds 100 }; throw 'Anchor build did not reach checkpoint' } finally { if (!$child.HasExited) { Stop-Process -InputObject $child -Force }; $child.WaitForExit() }" || goto failed
orderkey.exe verify-delivery --out "%OUT%\anchor-index" --selection-sha256 "%APPROVED%" > "%OUT%\incomplete.stdout"
if not errorlevel 1 goto failed
orderkey.exe build-selected --input "%INPUTS%\middle\input.jsonl" --source-contract "%TRAIN%\source.json" --queries "%TRAIN%\workload-4.json" --selection "%OUT%\selection-4" --assessment-batches "%INPUTS%\assessment-4.json" --assessment-sha256 "%ORDERKEY_REPLAY_ASSESSMENT%" --out "%OUT%\anchor-index" --resume > "%OUT%\resume.stdout" || goto failed
orderkey.exe verify-delivery --out "%OUT%\anchor-index" --selection-sha256 "%APPROVED%" > "%OUT%\anchor-ready.json" || goto failed
echo Terminated the anchor build, rejected the incomplete delivery, then resumed the approved layout.

mkdir "%INPUTS%\late" || goto failed
copy "%FIXTURE%\withheld\input.jsonl" "%INPUTS%\late\input.jsonl" >nul || goto failed
for %%N in (3 4) do (
    copy "%FIXTURE%\holdout-%%N.json" "%INPUTS%\holdout-%%N.json" >nul || goto failed
)
orderkey.exe build --input "%INPUTS%\late\input.jsonl" --source-contract "%TRAIN%\source.json" --target-contract "%OUT%\selection-4\target.contract" --out "%OUT%\late-index" > "%OUT%\build.stdout" || goto failed
call :gate 3 cap-3
if not "%ERRORLEVEL%"=="1" goto failed
call :gate 4 cap-4 || goto failed
call :gate 4 other-approval || goto failed
call :hash cap-4 receipt || goto failed
call :hash other-approval other || goto failed
set /p "TRUSTED="<"%OUT%\receipt.sha256"
set /p "OTHER="<"%OUT%\other.sha256"
approved-consumer.exe "%OUT%\late-index" "%OUT%\cap-4\batch-receipt.json" "%TRUSTED%" bounded "%OUT%\other-approval\batch-receipt.json" "%OTHER%" > "%OUT%\consumer.json" || goto failed
echo The holdout was rejected at 3 ranges and approved at 4 ranges. Reports in "%OUT%"
popd
exit /b 0

:gate
set /p "APPROVED="<"%FIXTURE%\approved-selection-%~1.sha256"
set /p "ASSESSMENT="<"%FIXTURE%\approved-assessment-%~1.sha256"
orderkey.exe gate-batch --selection "%OUT%\selection-%~1" --selection-sha256 "%APPROVED%" --assessment-sha256 "%ASSESSMENT%" --batches "%INPUTS%\holdout-%~1.json" --batch-id late --delivery "%OUT%\late-index" --scan-mode bounded --out "%OUT%\%~2" > "%OUT%\%~2.stdout"
exit /b %ERRORLEVEL%

:hash
set "ORDERKEY_REPLAY_RECEIPT=%OUT%\%~1\batch-receipt.json"
powershell -NoLogo -NoProfile -NonInteractive -Command "$sha=[Security.Cryptography.SHA256]::Create(); try { [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($env:ORDERKEY_REPLAY_RECEIPT))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }" > "%OUT%\%~2.sha256"
exit /b %ERRORLEVEL%

:failed
popd
exit /b 2
