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

$auth = "Integrated Security=True"
if ($Utilisateur -ne "") {
    $secret = Read-Host -AsSecureString "Mot de passe de $Utilisateur"
    $clair = [System.Net.NetworkCredential]::new("", $secret).Password
    $auth = "User ID=$Utilisateur;Password=$clair"
}

$sql = Get-Content -Raw -Encoding UTF8 -Path $Script
$chaine = "Server=$Serveur;Database=master;$auth;Application Name=CarteFlux;TrustServerCertificate=True"
$cn = New-Object System.Data.SqlClient.SqlConnection($chaine)
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
[System.IO.File]::WriteAllText($chemin, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("Fichier écrit : {0} ({1:N0} Ko)" -f $chemin, ($json.Length / 1024))
