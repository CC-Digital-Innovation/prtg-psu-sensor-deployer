# Create PSU Sensors using PrtgAPI
# Single-device deployment script
# https://github.com/CC-Digital-Innovation/prtg-psu-sensor-deployer

param(
    [Parameter(Mandatory=$true)]
    [string]$Server,
    [Parameter(Mandatory=$true)]
    [int]$DeviceId,
    [int]$PsuCount = 4,
    [switch]$WhatIf
)

# Load config file for credentials
$configPath = Join-Path $PSScriptRoot "config.ps1"
if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: config.ps1 not found. Copy config.sample.ps1 to config.ps1 and add your credentials." -ForegroundColor Red
    exit 1
}
. $configPath

if (-not $PrtgConfig -or -not $PrtgConfig.Username -or -not $PrtgConfig.Password) {
    Write-Host "ERROR: config.ps1 must define `$PrtgConfig with Username and Password" -ForegroundColor Red
    exit 1
}

# Skip certificate validation for PowerShell 5.1
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
    Add-Type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
}
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

Import-Module PrtgAPI
Connect-PrtgServer $Server (New-Credential $PrtgConfig.Username $PrtgConfig.Password) -IgnoreSSL

$client = Get-PrtgClient

Write-Host "=== CREATE PSU SENSORS ===" -ForegroundColor Cyan
Write-Host "Device ID: $DeviceId"
Write-Host "PSU Count: $PsuCount"
Write-Host ""

# Get device
$device = Get-Device -Id $DeviceId
if (-not $device) {
    Write-Host "ERROR: Device not found" -ForegroundColor Red
    exit 1
}
Write-Host "Device: $($device.Name)" -ForegroundColor Green

# Check for existing PSU sensors
$existing = $device | Get-Sensor | Where-Object { $_.Name -match 'ent state.*PowerSupply' }
if ($existing) {
    Write-Host "WARNING: Device already has $($existing.Count) PSU sensor(s)" -ForegroundColor Yellow
    $existing | ForEach-Object { Write-Host "  - $($_.Name)" }
    Write-Host ""
}

Write-Host ""
Write-Host "Getting SNMP Library targets from Arista OIDLIB..." -ForegroundColor Yellow

try {
    $targets = $device | Get-SensorTarget -RawType snmplibrary -qt "*Arista*" -Timeout 180
    Write-Host "Found $($targets.Count) total targets" -ForegroundColor Green

    # Filter for entStateOper OID AND PowerSupply, main entries only
    Write-Host ""
    Write-Host "Filtering for PowerSupply + entStateOper (main entries)..." -ForegroundColor Yellow

    $psuOperTargets = $targets | Where-Object {
        $isOper = $_.Value -match '\.131\.1\.1\.1\.3\.'
        $isPsu = ($_.Properties -join ' ') -match 'PowerSupply'
        $isMainEntry = $_.Value -match '000$'
        $isOper -and $isPsu -and $isMainEntry
    } | Sort-Object {
        if (($_.Properties -join ' ') -match 'PowerSupply(\d+)') { [int]$Matches[1] } else { 0 }
    }

    Write-Host "Found $($psuOperTargets.Count) main PSU targets:" -ForegroundColor Green
    $psuOperTargets | ForEach-Object {
        $propsText = $_.Properties -join ' '
        if ($propsText -match '(PowerSupply\d+)') {
            Write-Host "  - $($Matches[1]) (OID: $($_.Value))" -ForegroundColor Gray
        }
    }

    if ($psuOperTargets.Count -eq 0) {
        Write-Host "No PSU targets found" -ForegroundColor Yellow
        exit 0
    }

    # Create sensors using hashtable + New-SensorParameters with DynamicType
    # Per PrtgAPI issues #47 and #98
    Write-Host ""
    Write-Host "Creating sensors..." -ForegroundColor Cyan

    $selectedTargets = $psuOperTargets | Select-Object -First $PsuCount

    foreach ($target in $selectedTargets) {
        $propsText = $target.Properties -join ' '
        $psuName = if ($propsText -match '(PowerSupply\d+)') { $Matches[1] } else { "PowerSupply" }
        $sensorName = "ent state: $psuName - ent state oper"

        if ($WhatIf) {
            Write-Host "  [WhatIf] Would create: $sensorName" -ForegroundColor Gray
            continue
        }

        Write-Host "  Creating: $sensorName" -ForegroundColor Yellow

        try {
            # Build sensor parameters as hashtable per GitHub issue #47
            # The interfacenumber__check must be ALL Properties joined with pipes!
            $fullTargetValue = $target.Properties -join '|'

            $sensorTable = @{
                "name_" = $sensorName
                "sensortype" = "snmplibrary"
                "library_" = "Arista & PA Hardware State.oidlib"
                "interfacenumber_" = 1
                "interfacenumber__check" = $fullTargetValue
                "tags_" = "psu powersupply snmplibrary"
                "priority_" = 3
            }

            # Create parameters with DynamicType flag (critical for snmplibrary)
            $params = New-SensorParameters $sensorTable -DynamicType

            # Add sensor - DynamicType allows resolution of snmpcustomtable type
            $sensor = $device | Add-Sensor $params
            Write-Host "    Created sensor ID: $($sensor.Id)" -ForegroundColor Green
        } catch {
            Write-Host "    Error: $_" -ForegroundColor Red
        }

        # Small delay between sensor creations
        Start-Sleep -Seconds 2
    }

} catch {
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
}

Write-Host ""
Write-Host "=== COMPLETE ===" -ForegroundColor Cyan
