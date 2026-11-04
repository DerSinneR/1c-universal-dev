[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
$resolved = Resolve-Path -LiteralPath $Path
if ($resolved.Count -ne 1) {
    throw 'Укажите один файл .bsl или один каталог.'
}

$target = Get-Item -LiteralPath $resolved.Path
if ($target.PSIsContainer) {
    $files = @(Get-ChildItem -LiteralPath $target.FullName -Recurse -File -Filter '*.bsl')
}
elseif ($target.Extension -ieq '.bsl') {
    $files = @($target)
}
else {
    throw 'Путь должен указывать на файл .bsl или каталог с файлами .bsl.'
}

if ($files.Count -eq 0) {
    throw 'В указанном пути не найдены файлы .bsl.'
}

$findings = [System.Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $loopDepth = 0
    $tryFrames = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('//')) {
            continue
        }

        # Отмечаем содержимое блока Исключение до обработки его завершающих операторов.
        if ($tryFrames.Count -gt 0 -and $trimmed -and $trimmed -notmatch '^КонецПопытки\b') {
            $frame = $tryFrames[$tryFrames.Count - 1]
            if ($frame.InException -and $trimmed -notmatch '^Исключение\b') {
                $frame.HasExceptionStatement = $true
            }
        }

        if ($trimmed -match '^(Пока\b|Для(?:\s+каждого)?\b).*\bЦикл\b') {
            $loopDepth++
        }

        if ($loopDepth -gt 0 -and $line -match '\bЗапрос\w*\s*\.\s*Выполнить(?:Пакет)?\s*\(') {
            $findings.Add([pscustomobject]@{
                File = $file.FullName
                Line = $i + 1
                Rule = 'QUERY-IN-LOOP'
                Message = 'Вызов Запрос.Выполнить внутри цикла может многократно обращаться к СУБД; проверьте возможность пакетного запроса или переноса выполнения.'
            })
        }

        if ($line -match '(?<![.\w])Выполнить\s*\(') {
            $findings.Add([pscustomobject]@{
                File = $file.FullName
                Line = $i + 1
                Rule = 'DYNAMIC-EXECUTION'
                Message = 'Найдено динамическое выполнение кода; проверьте допустимость, источник текста и возможность безопасной альтернативы.'
            })
        }

        if ($trimmed -match '^Попытка\s*$') {
            $tryFrames.Add([pscustomobject]@{
                InException = $false
                ExceptionLine = 0
                HasExceptionStatement = $false
            })
        }
        elseif ($trimmed -match '^Исключение\s*$' -and $tryFrames.Count -gt 0) {
            $frame = $tryFrames[$tryFrames.Count - 1]
            $frame.InException = $true
            $frame.ExceptionLine = $i + 1
        }
        elseif ($trimmed -match '^КонецПопытки\s*;?\s*$' -and $tryFrames.Count -gt 0) {
            $frame = $tryFrames[$tryFrames.Count - 1]
            if ($frame.InException -and -not $frame.HasExceptionStatement) {
                $findings.Add([pscustomobject]@{
                    File = $file.FullName
                    Line = $frame.ExceptionLine
                    Rule = 'EMPTY-EXCEPTION'
                    Message = 'Блок Исключение выглядит пустым; проверьте, не теряется ли причина ошибки.'
                })
            }
            $tryFrames.RemoveAt($tryFrames.Count - 1)
        }

        if ($trimmed -match '^КонецЦикла\b' -and $loopDepth -gt 0) {
            $loopDepth--
        }
    }
}

if ($findings.Count -eq 0) {
    Write-Output "Проверено файлов: $($files.Count). Поддерживаемые паттерны не найдены."
}
else {
    foreach ($finding in $findings) {
        Write-Output "$($finding.File):$($finding.Line): [$($finding.Rule)] $($finding.Message)"
    }
    Write-Output "Проверено файлов: $($files.Count). Кандидатов на ревью: $($findings.Count)."
}

Write-Output 'Это эвристический сканер: возможны пропуски и ложные срабатывания. Результаты требуют ручной проверки.'
