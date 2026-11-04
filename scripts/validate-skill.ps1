[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$SkillPath = (Join-Path $PSScriptRoot '..'),

    [switch]$Public
)

$ErrorActionPreference = 'Stop'
$issues = [System.Collections.Generic.List[string]]::new()
$checks = [System.Collections.Generic.List[string]]::new()

function Add-Check {
    param([string]$Message)
    $script:checks.Add($Message)
}

function Add-Issue {
    param([string]$Message)
    $script:issues.Add($Message)
}

try {
    $root = (Resolve-Path -LiteralPath $SkillPath).Path
    $skillFile = Join-Path $root 'SKILL.md'
    $changelogFile = Join-Path $root 'CHANGELOG.md'
    $readmeFile = Join-Path $root 'README.md'
    $agentFile = Join-Path $root 'agents/openai.yaml'

    foreach ($required in @($skillFile, $changelogFile, $readmeFile, $agentFile)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            Add-Issue "Не найден обязательный файл: $required"
        }
    }

    $skillText = Get-Content -LiteralPath $skillFile -Raw -Encoding UTF8
    $changelogText = Get-Content -LiteralPath $changelogFile -Raw -Encoding UTF8
    $agentText = Get-Content -LiteralPath $agentFile -Raw -Encoding UTF8
    $frontMatter = [regex]::Match($skillText, '\A---\r?\n(?<yaml>.*?)\r?\n---\r?\n', [System.Text.RegularExpressions.RegexOptions]::Singleline)

    if (-not $frontMatter.Success) {
        Add-Issue 'SKILL.md: отсутствует корректная пара ограничителей YAML-frontmatter.'
        $yamlText = ''
    }
    else {
        $yamlText = $frontMatter.Groups['yaml'].Value
        if ($yamlText -notmatch '(?m)^name:\s*1c-universal-dev\s*$') {
            Add-Issue 'SKILL.md: поле name должно быть 1c-universal-dev.'
        }

        if ($yamlText -notmatch '(?m)^description:\s*"[^"\r\n]*"\s*$') {
            Add-Issue 'SKILL.md: description должна быть одной строкой в двойных кавычках.'
        }

        $versionMatch = [regex]::Match($yamlText, '(?m)^\s{2}version:\s*"(?<version>\d+\.\d+\.\d+)"\s*$')
        if (-not $versionMatch.Success) {
            Add-Issue 'SKILL.md: metadata.version отсутствует или не соответствует формату X.Y.Z.'
        }
        else {
            $version = $versionMatch.Groups['version'].Value
            $latestEntry = [regex]::Match($changelogText, '(?m)^## v(?<version>\d+\.\d+\.\d+) — \d{4}-\d{2}-\d{2}\s*$')
            if (-not $latestEntry.Success -or $latestEntry.Groups['version'].Value -ne $version) {
                Add-Issue "Версия в SKILL.md ($version) не совпадает с первой записью CHANGELOG.md."
            }
            else {
                Add-Check "версия $version совпадает с CHANGELOG.md"
            }
        }
    }

    $markdownFiles = Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md' |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
    foreach ($markdownFile in $markdownFiles) {
        $text = Get-Content -LiteralPath $markdownFile.FullName -Raw -Encoding UTF8
        foreach ($match in [regex]::Matches($text, '(?:references|user-context)/[A-Za-z0-9_.-]+\.md')) {
            $relative = $match.Value -replace '/', [string][System.IO.Path]::DirectorySeparatorChar
            $target = Join-Path $root $relative
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                Add-Issue "Ссылка на отсутствующий reference: $($markdownFile.FullName) -> $($match.Value)"
            }
        }
    }
    Add-Check 'все пути references/*.md и user-context/*.md существуют'

    $allMarkdownText = ($markdownFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
    $referenceFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'references') -Recurse -File -Filter '*.md')
    foreach ($referenceFile in $referenceFiles) {
        $relative = $referenceFile.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/')) -replace '\\', '/'
        if ($allMarkdownText -notmatch [regex]::Escape($relative)) {
            Add-Issue "Reference не подключён ни из одного Markdown-файла: $relative"
        }
    }
    Add-Check 'каждый reference-файл доступен по ссылке из набора Markdown'

    foreach ($template in @('ШАБЛОН_ВНЕШНИЙ_ОТЧЕТ', 'ШАБЛОН_ВНЕШНЯЯ_ОБРАБОТКА')) {
        $templatePath = Join-Path $root $template
        if (-not (Test-Path -LiteralPath $templatePath -PathType Container)) {
            Add-Issue "Отсутствует каталог шаблона $template."
            continue
        }

        $xmlFiles = @(Get-ChildItem -LiteralPath $templatePath -Recurse -File -Filter '*.xml')
        if ($xmlFiles.Count -eq 0) {
            Add-Issue "В каталоге шаблона $template нет XML-файлов."
        }
    }
    Add-Check 'оба XML-шаблона содержат файлы *.xml'

    if ($agentText -notmatch '(?m)^\s*allow_implicit_invocation:\s*true\s*$') {
        Add-Issue 'agents/openai.yaml: не найдено allow_implicit_invocation: true; проверьте, что это изменение намеренное.'
    }
    if ($agentText -notmatch '\$1c-universal-dev') {
        Add-Issue 'agents/openai.yaml: default_prompt должен явно упоминать $1c-universal-dev.'
    }
    Add-Check 'agents/openai.yaml сохраняет имя skill и обычный режим вызова'

    if ($Public) {
        $profilePath = Join-Path $root 'user-context/user-preferences.yaml'
        $ignoreFile = Join-Path $root '.gitignore'
        if (Test-Path -LiteralPath $profilePath) {
            Add-Issue 'Публичный пакет содержит персональный файл user-context/user-preferences.yaml.'
        }
        if (-not (Test-Path -LiteralPath $ignoreFile -PathType Leaf)) {
            Add-Issue 'Публичный пакет должен содержать .gitignore, чтобы персональный профиль не попал в Git при последующем использовании.'
        }
        elseif ((Get-Content -LiteralPath $ignoreFile -Raw -Encoding UTF8) -notmatch '(?m)^\s*/?user-context/user-preferences\.yaml\s*$') {
            Add-Issue '.gitignore не исключает персональный файл user-context/user-preferences.yaml.'
        }
        if (Test-Path -LiteralPath (Join-Path $root '.git')) {
            Add-Issue 'Публичный пакет содержит каталог .git; перед загрузкой используйте папку без истории репозитория.'
        }
        Add-Check 'публичная папка не содержит профиль или .git, а .gitignore исключает локальные настройки'
    }

    foreach ($check in $checks) {
        Write-Host "OK  $check"
    }
    if ($issues.Count -gt 0) {
        foreach ($issue in $issues) {
            Write-Host "FAIL $issue"
        }
        Write-Host "Проверок: $($checks.Count); проблем: $($issues.Count)."
        exit 1
    }

    Write-Host "Проверок: $($checks.Count); проблем не найдено."
    exit 0
}
catch {
    Write-Error "Проверка не завершена: $($_.Exception.Message)"
    exit 2
}
