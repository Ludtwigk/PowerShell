param([String]$PathFrom, [String]$PathTo)

$images = New-Object System.Collections.ArrayList
$videos = New-Object System.Collections.ArrayList
$years = New-Object System.Collections.ArrayList


$all = Get-ChildItem -Path $PathFrom -Recurse -File | Sort-Object -Property LastWriteTime.Year

$all | ForEach-Object { 
    [void]$years.Add($_.LastWriteTime.Year)
}

$years = $years | Sort-Object -Unique

$years | ForEach-Object {
    $fp = $PathTo + "\" + $_
    [System.IO.Directory]::CreateDirectory($fp)
    [System.IO.Directory]::CreateDirectory($fp + "\Images")
    [System.IO.Directory]::CreateDirectory($fp + "\Videos")
}

$all | ForEach-Object {
    if ($_.Extension -iin ".mov",".mp4") {
        $moveTo = $PathTo + "\" + $_.LastWriteTime.Year + "\Videos"
        $_ | Move-Item -Destination $moveTo
    } else {
        $moveTo = $PathTo + "\" + $_.LastWriteTime.Year + "\Images"
        $_ | Move-Item -Destination $moveTo
    }
}

