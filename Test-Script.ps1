Write-Host "Test-Script"

$array = @("1", "2", "3")

$array | ForEach-Object {
    Write-Host $_
}