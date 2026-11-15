<#
  Lance extraction-query-store.sql sur une instance et écrit le JSON attendu par index.html.
  Aucun module à installer : utilise le client SQL fourni avec PowerShell.
  Authentification Windows par défaut ; préciser -Utilisateur pour une authentification SQL.
#>
param(
    [Parameter(Mandatory = $true)][string]$Serveur,
    [string]$Sortie = "flux.json",
    [string]$Script = (Join-Path (Split-Path $PSScriptRoot -Parent) "sql/extraction-query-store.sql"),
    [string]$Utilisateur = "",
    [int]$DelaiSecondes = 1800
)

$ErrorActionPreference = "Stop"

# Le client SQL historique est fourni avec Windows PowerShell 5.1 et avec PowerShell 7.
if (-not ("System.Data.SqlClient.SqlConnection" -as [type])) {
    try { Add-Type -AssemblyName "System.Data.SqlClient" } catch { }
}
if (-not ("System.Data.SqlClient.SqlConnection" -as [type])) {
    throw "Client SQL introuvable dans cette version de PowerShell. Utiliser Windows PowerShell 5.1, ou exécuter le script SQL dans SSMS ou Azure Data Studio."
}
if (-not (Test-Path -LiteralPath $Script)) { throw "Script SQL introuvable : $Script" }

$sql = Get-Content -Raw -Encoding UTF8 -LiteralPath $Script

# La chaîne de connexion est construite champ par champ, et le mot de passe n'y figure jamais :
# un nom de serveur ou un mot de passe contenant ";" ou "=" ne peut pas la casser.
$cs = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$cs["Data Source"] = $Serveur
$cs["Initial Catalog"] = "master"
$cs["Application Name"] = "Sillage"
$cs["TrustServerCertificate"] = $true
if ($Utilisateur -eq "") { $cs["Integrated Security"] = $true }

$cn = New-Object System.Data.SqlClient.SqlConnection($cs.ConnectionString)
if ($Utilisateur -ne "") {
    $secret = Read-Host -AsSecureString "Mot de passe de $Utilisateur"
    $secret.MakeReadOnly()
    $cn.Credential = New-Object System.Data.SqlClient.SqlCredential($Utilisateur, $secret)
}
$cn.Open()
try {
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = $DelaiSecondes
    $json = [string]$cmd.ExecuteScalar()
}
finally {
    $cn.Close()
}

if ([string]::IsNullOrEmpty($json)) { throw "L'extraction n'a renvoyé aucun document." }

$chemin = $Sortie
if (-not [System.IO.Path]::IsPathRooted($chemin)) { $chemin = Join-Path (Get-Location) $chemin }
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($chemin, $json, $utf8)
Write-Host ("Fichier écrit : {0} ({1:N0} Ko)" -f $chemin, ($utf8.GetByteCount($json) / 1024))
