<#
.SYNOPSIS
  Planifie la récupération quotidienne des sauvegardes (tâche planifiée Windows).

.DESCRIPTION
  Crée ou remplace, pour l'utilisateur courant, une tâche qui lance
  recuperer-sauvegardes.ps1 (même dossier que ce script) :
    - chaque jour à HeureQuotidienne ;
    - à l'ouverture de session, après 5 minutes (rattrapage d'un PC resté éteint) ;
    - dès que possible si un démarrage planifié a été manqué.

  Le PC doit être allumé, connecté au réseau et la session ouverte : la tâche tourne
  avec le compte courant (propriétaire de la clé ~/.ssh/dinthialma_backup), sans mot
  de passe enregistré et sans droits administrateur. Les jours manqués sont rattrapés
  tant qu'ils sont encore sur le VPS (14 jours).

  Résultat : colonne « Résultat de la dernière exécution » du Planificateur de tâches
  (0 = OK, 0x1 = erreur, 0x2 = copie la plus récente trop ancienne) et journal dans
  D:\Sauvegardes\dinthialma\journaux. Relancer ce script remplace la tâche.

.EXAMPLE
  .\planifier-recuperation.ps1 -Hote 203.0.113.10

.EXAMPLE
  # Lancer la tâche tout de suite pour tester
  Start-ScheduledTask -TaskName 'Dinthialma - Recuperation des sauvegardes'
#>
param(
  [Parameter(Mandatory = $true)] [string] $Hote,
  [string] $HeureQuotidienne = '08:00',
  [string] $NomTache = 'Dinthialma - Recuperation des sauvegardes'
)

$ErrorActionPreference = 'Stop'

$script = Join-Path $PSScriptRoot 'recuperer-sauvegardes.ps1'
if (-not (Test-Path $script)) { throw "Script introuvable : $script" }
$utilisateur = "$env:USERDOMAIN\$env:USERNAME"

$arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Hote {1}' -f $script, $Hote
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $PSScriptRoot

$quotidien = New-ScheduledTaskTrigger -Daily -At $HeureQuotidienne
$ouverture = New-ScheduledTaskTrigger -AtLogOn -User $utilisateur
# Laisser au réseau (Wi-Fi, VPN) le temps de se connecter après l'ouverture de session
$ouverture.Delay = 'PT5M'

$parametres = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew

# Interactive : pas de mot de passe stocké ; la tâche tourne quand la session est ouverte
$principal = New-ScheduledTaskPrincipal -UserId $utilisateur -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $NomTache -Action $action -Trigger $quotidien, $ouverture `
  -Settings $parametres -Principal $principal -Force `
  -Description "Copie hors du VPS des sauvegardes PostgreSQL ($Hote) - spirit-infra/scripts/windows" | Out-Null

Write-Output "Tâche « $NomTache » enregistrée : chaque jour à $HeureQuotidienne et à l'ouverture de session."
Write-Output "Test immédiat : Start-ScheduledTask -TaskName '$NomTache'"
