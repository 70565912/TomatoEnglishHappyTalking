function Assert-FlutterToolReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FlutterRoot
    )

    foreach ($name in @("flutter.bat.lock", "lockfile")) {
        $path = Join-Path $FlutterRoot "bin\cache\$name"
        $handle = $null
        try {
            $handle = [System.IO.File]::Open(
                $path,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch {
            throw @"
Flutter SDK lock is held or its cache is not writable:
  $path

Do not invoke flutter.bat from this process. Wait for the active Flutter task,
or run with permission to write the Flutter SDK cache.
"@
        } finally {
            if ($null -ne $handle) {
                $handle.Dispose()
            }
        }
    }
}
