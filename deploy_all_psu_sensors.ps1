# Deploy PSU Sensors to Arista and Palo Alto Devices
# Auto-detects PSU count per device and creates sensors for all found
# https://github.com/YOUR_USERNAME/prtg-psu-sensor-deployer

param(
    [Parameter(Mandatory=$true)]
    [string]$Server,
    [switch]$WhatIf,
    [string]$ReportPath,
    [int]$MaxDevices = 0  # 0 = all devices, or limit for testing
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

# Default report path includes server name
if (-not $ReportPath) {
    $serverShort = $Server -replace '\..*$', ''
    $ReportPath = Join-Path $PSScriptRoot "psu_deployment_${serverShort}.csv"
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

# Initialize report
$report = @()
$startTime = Get-Date

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  PSU SENSOR MASS DEPLOYMENT" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Server: $Server"
Write-Host "Started: $startTime"
Write-Host "Report: $ReportPath"
if ($WhatIf) { Write-Host "MODE: WhatIf (no changes will be made)" -ForegroundColor Yellow }
Write-Host ""

# Get Arista switches (exclude APs: C-260, O-235) and Palo Alto devices (exclude Panorama)
Write-Host "Querying Arista and Palo Alto devices..." -ForegroundColor Yellow
$allDevices = Get-Device | Where-Object {
    ($_.Name -match '^Arista' -and $_.Name -notmatch 'C-260|O-235') -or
    ($_.Name -match '^Palo Alto' -and $_.Name -notmatch 'Panorama')
} | Sort-Object Name

Write-Host "Found $($allDevices.Count) target devices" -ForegroundColor Green

if ($MaxDevices -gt 0) {
    $allDevices = $allDevices | Select-Object -First $MaxDevices
    Write-Host "Limited to first $MaxDevices devices for testing" -ForegroundColor Yellow
}

Write-Host ""

# Counters
$processed = 0
$created = 0
$skipped = 0
$failed = 0
$totalSensorsCreated = 0

foreach ($device in $allDevices) {
    $processed++
    $deviceStart = Get-Date
    $sensorsCreated = @()
    $status = "Unknown"
    $message = ""

    # Extract vendor and model from device name
    $vendor = if ($device.Name -match '^Arista') { "Arista" } elseif ($device.Name -match '^Palo Alto') { "PaloAlto" } else { "Unknown" }
    $model = if ($device.Name -match '(Arista|Palo Alto)\s+(\S+)') { $Matches[2] } else { "Unknown" }

    Write-Host "[$processed/$($allDevices.Count)] $($device.Name)" -ForegroundColor Cyan
    Write-Host "  Vendor: $vendor | Model: $model | Group: $($device.Group)" -ForegroundColor Gray

    try {
        # Check for existing PSU sensors
        $existing = $device | Get-Sensor | Where-Object { $_.Name -match 'ent state.*PowerSupply' }
        if ($existing -and $existing.Count -gt 0) {
            Write-Host "  SKIPPED: Already has $($existing.Count) PSU sensor(s)" -ForegroundColor Yellow
            $skipped++
            $status = "Skipped"
            $message = "Already has $($existing.Count) PSU sensors"

            $report += [PSCustomObject]@{
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                DeviceId = $device.Id
                DeviceName = $device.Name
                Vendor = $vendor
                Model = $model
                Group = $device.Group
                PsusFound = 0
                SensorsCreated = 0
                SensorIds = ""
                Status = $status
                Message = $message
            }
            Write-Host ""
            continue
        }

        # Discover PSU targets (library name: "Arista & PA Hardware State.oidlib")
        Write-Host "  Discovering PSU targets..." -ForegroundColor Gray
        $targets = $device | Get-SensorTarget -RawType snmplibrary -qt "*Hardware State*" -Timeout 180

        # Filter for main PSU entStateOper entries only
        # Arista: "PowerSupply1", OID .3.XXXXX1000 (not Fan entries ending in 1210/1211)
        # Palo Alto: "Power Supply #1 (left)", OID .3.9 or .3.10
        $psuTargets = $targets | Where-Object {
            $propsText = $_.Properties -join ' '
            $isEntStateOper = $_.Value -match '\.131\.1\.1\.1\.3\.'
            $isPsu = $propsText -match 'Power\s*Supply'
            $isNotFan = $propsText -notmatch 'Fan|Speed'
            # For Arista, main PSU entries end in X1000 (not X1210/X1211 which are fans)
            $isMainEntry = ($_.Value -match '1000$') -or ($_.Value -match '\.\d{1,2}$')
            $isEntStateOper -and $isPsu -and $isNotFan -and $isMainEntry
        } | Sort-Object {
            $propsText = $_.Properties -join ' '
            if ($propsText -match 'PowerSupply(\d+)') { [int]$Matches[1] }
            elseif ($propsText -match 'Power Supply #(\d+)') { [int]$Matches[1] }
            else { 0 }
        }

        $psuCount = $psuTargets.Count
        Write-Host "  Found $psuCount PSU target(s)" -ForegroundColor Green

        if ($psuCount -eq 0) {
            Write-Host "  SKIPPED: No PSU targets found" -ForegroundColor Yellow
            $skipped++
            $status = "Skipped"
            $message = "No PSU targets discovered"

            $report += [PSCustomObject]@{
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                DeviceId = $device.Id
                DeviceName = $device.Name
                Vendor = $vendor
                Model = $model
                Group = $device.Group
                PsusFound = 0
                SensorsCreated = 0
                SensorIds = ""
                Status = $status
                Message = $message
            }
            Write-Host ""
            continue
        }

        # Create sensors for ALL discovered PSUs
        foreach ($target in $psuTargets) {
            $propsText = $target.Properties -join ' '
            # Extract PSU name - handle both Arista (PowerSupply1) and PA (Power Supply #1 (left)) formats
            if ($propsText -match '(PowerSupply\d+)') {
                $psuName = $Matches[1]
            } elseif ($propsText -match '(Power Supply #\d+[^)]*\))') {
                $psuName = $Matches[1]
            } else {
                $psuName = "PowerSupply"
            }
            $sensorName = "ent state: $psuName - ent state oper"

            if ($WhatIf) {
                Write-Host "  [WhatIf] Would create: $sensorName" -ForegroundColor Gray
                $sensorsCreated += "WhatIf"
                continue
            }

            try {
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

                $params = New-SensorParameters $sensorTable -DynamicType
                $sensor = $device | Add-Sensor $params

                Write-Host "  Created: $sensorName (ID: $($sensor.Id))" -ForegroundColor Green
                $sensorsCreated += $sensor.Id
                $totalSensorsCreated++

                Start-Sleep -Seconds 1
            } catch {
                Write-Host "  ERROR creating $sensorName : $_" -ForegroundColor Red
            }
        }

        if ($sensorsCreated.Count -gt 0) {
            $created++
            $status = "Success"
            $message = "Created $($sensorsCreated.Count) sensors"
        } else {
            $status = "NoAction"
            $message = "No sensors created"
        }

        $report += [PSCustomObject]@{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            DeviceId = $device.Id
            DeviceName = $device.Name
            Vendor = $vendor
            Model = $model
            Group = $device.Group
            PsusFound = $psuCount
            SensorsCreated = $sensorsCreated.Count
            SensorIds = ($sensorsCreated -join ",")
            Status = $status
            Message = $message
        }

    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
        $failed++

        $report += [PSCustomObject]@{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            DeviceId = $device.Id
            DeviceName = $device.Name
            Vendor = $vendor
            Model = $model
            Group = $device.Group
            PsusFound = 0
            SensorsCreated = 0
            SensorIds = ""
            Status = "Error"
            Message = $_.ToString()
        }
    }

    $elapsed = (Get-Date) - $deviceStart
    Write-Host "  Time: $($elapsed.TotalSeconds.ToString('F1'))s" -ForegroundColor Gray
    Write-Host ""
}

# Export report
if (-not $WhatIf) {
    $report | Export-Csv -Path $ReportPath -NoTypeInformation
    Write-Host "Report saved: $ReportPath" -ForegroundColor Green
}

# Summary
$endTime = Get-Date
$totalTime = $endTime - $startTime

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Duration: $($totalTime.ToString('hh\:mm\:ss'))"
Write-Host ""
Write-Host "Devices Processed: $processed" -ForegroundColor White
Write-Host "  - Created sensors: $created" -ForegroundColor Green
Write-Host "  - Skipped: $skipped" -ForegroundColor Yellow
Write-Host "  - Failed: $failed" -ForegroundColor Red
Write-Host ""
Write-Host "Total Sensors Created: $totalSensorsCreated" -ForegroundColor Green
