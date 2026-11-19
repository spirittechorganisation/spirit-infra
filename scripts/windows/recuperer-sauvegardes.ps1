<#
.SYNOPSIS
  Copie hors du VPS : récupère les sauvegardes PostgreSQL sur ce poste Windows.

.DESCRIPTION
  C'est ce poste qui va chercher les fichiers (le VPS n'a jamais accès au poste).
  Connexion SFTP en lecture seule avec l'utilisateur « backup-reader »
  (voir scripts/installer-lecteur-sauvegardes.sh côté VPS).

  - ne récupère que les dossiers complets (fichier SAUVEGARDE_TERMINEE) ;
  - télécharge dans un dossier temporaire puis renomme : jamais de copie partielle ;
  - vérifie la présence de globals.sql et d'au moins un .dump non vide ;
  - supprime les copies locales de plus de RetentionJours jours ;
  - code de sortie 2 si la copie la plus récente a plus de AlerteJours jours
    (visible dans l'historique du Planificateur de tâches).

  Les sauvegardes contiennent des données personnelles : garder Destination sur un
  disque chiffré (BitLocker) et hors de tout dossier synchronisé (OneDrive, Drive...).

.EXAMPLE
  .\recuperer-sauvegardes.ps1 -Hote 203.0.113.10
#>
param(
  [Parameter(Mandatory = $true)] [string] $Hote,
  [string] $Utilisateur = 'backup-reader',
  [string] $Cle = (Join-Path $HOME '.ssh\dinthialma_backup'),
  [string] $Destination = 'D:\Sauvegardes\dinthialma\postgres',
  [string] $Journaux = 'D:\Sauvegardes\dinthialma\journaux',
  [int] $RetentionJours = 30,
  [int] $AlerteJours = 2,
  [int] $Port = 22,
  # Fichier known_hosts dédié (facultatif) ; par défaut celui de l'utilisateur
  [string] $HotesConnus = ''
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Destination, $Journaux | Out-Null
$journal = Join-Path $Journaux ("recuperation-{0:yyyy-MM}.log" -f (Get-Date))

function Write-Journal([string] $message) {
  $ligne = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $message
  Write-Output $ligne
  Add-Content -Path $journal -Value $ligne -Encoding UTF8
}

# BatchMode : aucune question interactive (tâche planifiée) ; un hôte inconnu fait
# échouer la connexion — se connecter une première fois à la main pour l'accepter.
$sshOptions = @('-i', $Cle, '-P', $Port, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20')
if ($HotesConnus) { $sshOptions += @('-o', "UserKnownHostsFile=$HotesConnus") }
$cible = "$Utilisateur@$Hote"
$formatJour = '^\d{4}-\d{2}-\d{2}$'

try {
  Write-Journal "Début de la récupération depuis $cible"

  # 1. Dossiers disponibles sur le VPS (le chroot montre /opt/backups comme /)
  # (pas de « 2>&1 » : sous PowerShell 5.1 avec ErrorActionPreference=Stop, rediriger
  # stderr d'un programme externe lève une exception même en cas de succès)
  # Commandes passées par un fichier ASCII et non par un pipe : sous PowerShell 5.1, si
  # la console est en UTF-8 (option Windows « UTF-8 bêta »), le pipe vers un programme
  # externe ajoute un BOM devant la commande et sftp répond « Invalid command ».
  $lot = [System.IO.Path]::GetTempFileName()
  try {
    [System.IO.File]::WriteAllText($lot, "ls -1 /postgres`n", [System.Text.Encoding]::ASCII)
    $listing = & sftp.exe -q @sshOptions -b $lot $cible
    $codeSftp = $LASTEXITCODE
  }
  finally { Remove-Item -Force $lot -ErrorAction SilentlyContinue }
  if ($codeSftp -ne 0) { throw "Connexion SFTP impossible (code $codeSftp), voir le message ci-dessus" }
  $distants = $listing | ForEach-Object { ($_ -split '/')[-1].Trim() } |
    Where-Object { $_ -match $formatJour } | Sort-Object -Unique

  # 2. Téléchargement des jours absents en local
  foreach ($jour in $distants) {
    $final = Join-Path $Destination $jour
    if (Test-Path (Join-Path $final 'SAUVEGARDE_TERMINEE')) { continue }

    $temporaire = Join-Path $Destination ".partiel-$jour"
    if (Test-Path $temporaire) { Remove-Item -Recurse -Force $temporaire }
    New-Item -ItemType Directory -Path $temporaire | Out-Null

    & scp.exe -q @sshOptions "${cible}:/postgres/$jour/*" "$temporaire\" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Remove-Item -Recurse -Force $temporaire
      Write-Journal "IGNORÉ $jour : téléchargement en échec (sauvegarde en cours ?)"
      continue
    }

    $termine = Test-Path (Join-Path $temporaire 'SAUVEGARDE_TERMINEE')
    $globals = Test-Path (Join-Path $temporaire 'globals.sql')
    $dumps = @(Get-ChildItem -Path $temporaire -Filter '*.dump' | Where-Object { $_.Length -gt 0 })
    if (-not ($termine -and $globals -and $dumps.Count -gt 0)) {
      Remove-Item -Recurse -Force $temporaire
      Write-Journal "IGNORÉ $jour : dossier incomplet sur le VPS"
      continue
    }

    if (Test-Path $final) { Remove-Item -Recurse -Force $final }
    Rename-Item -Path $temporaire -NewName $jour
    $taille = ($dumps | Measure-Object -Property Length -Sum).Sum / 1MB
    Write-Journal ("OK {0} : {1} base(s), {2:N1} Mo" -f $jour, $dumps.Count, $taille)
  }

  # 3. Rotation locale
  $limite = (Get-Date).Date.AddDays(-$RetentionJours)
  Get-ChildItem -Path $Destination -Directory | Where-Object { $_.Name -match $formatJour } |
    Where-Object { [datetime]::ParseExact($_.Name, 'yyyy-MM-dd', $null) -lt $limite } |
    ForEach-Object {
      Remove-Item -Recurse -Force $_.FullName
      Write-Journal "SUPPRIMÉ $($_.Name) (plus de $RetentionJours jours)"
    }

  # 4. Alerte si la copie la plus récente est trop ancienne
  $locaux = Get-ChildItem -Path $Destination -Directory |
    Where-Object { $_.Name -match $formatJour -and (Test-Path (Join-Path $_.FullName 'SAUVEGARDE_TERMINEE')) } |
    Sort-Object Name
  if (-not $locaux) {
    Write-Journal "ALERTE : aucune sauvegarde complète en local"
    exit 2
  }
  $derniere = [datetime]::ParseExact($locaux[-1].Name, 'yyyy-MM-dd', $null)
  $age = ((Get-Date).Date - $derniere).Days
  if ($age -gt $AlerteJours) {
    Write-Journal "ALERTE : la sauvegarde la plus récente date de $age jours ($($locaux[-1].Name))"
    exit 2
  }

  Write-Journal "Terminé : dernière sauvegarde locale $($locaux[-1].Name), $($locaux.Count) jour(s) conservé(s)"
  exit 0
}
catch {
  Write-Journal "ERREUR : $($_.Exception.Message)"
  exit 1
}
