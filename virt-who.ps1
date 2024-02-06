#!/usr/bin/pwsh
#Requires -Modules Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore
#Requires -Modules VMware.PowerCLI


$User = "svc_VC_RHEL"
$PwSS = Get-Secret $User
$cred = [System.Management.Automation.PSCredential]::New($User,$PwSS)
# Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope User -ParticipateInCeiP $false -DefaultVIServerMode Multiple
$VIServer = Connect-VIServer -Server vcenter.example.com -Credential $cred

# Limit to entitled clusters.
$hosts = Get-Cluster -Name "RHEL Cluster","SAP Cluster","Splunk Cluster" | Get-VMHost
$hypervisors = $hosts |
    Select-Object -Property @(
        @{N='name';E={$_.Name.Split('.')[0]}}
        @{N='uuid';E={$_.Name.Split('.')[0]}}
        @{N='cpu.sockets';E={$_.ExtensionData.Hardware.CpuInfo.NumCpuPackages}}
        @{N='dmi.system.uuid';E={(Get-Esxcli -VMHost $_ -V2).system.uuid.get.invoke()}} # Get ESXi System UUID from esxcli instead of the Hardware BIOS UUID.
        @{N='cluster';E={$_.Parent.Name}}
        @{N='version';E={$_.Version}}
        @{N='guests';E={($_|Get-VM|Where-Object {$_.Guest.GuestFamily -like "linuxGuest"})}}
    )

$virtwho = @{hypervisors = @()}
foreach ($hypervisor in $hypervisors) {
    $guests = @()
    foreach ($guest in $hypervisor.guests) {
        $guests += @{
            guestId = $guest.ExtensionData.Config.Uuid
            state = if ($guest.ExtensionData.Runtime.PowerState -like "PoweredOn") {1} else {0}
            attributes = @{
                virtWhoType = "esx"
                active = if ($guest.ExtensionData.Runtime.ConnectionState -like "connected") {1} else {0}
            }
        }
    }
    $facts = @{}
    $facts.add('cpu.cpusockets(s)', $hypervisor.'cpu.sockets')
    $facts.add('hypervisor.type', 'VMware ESXi')
    $facts.add('dmi.system.uuid', $hypervisor.'dmi.system.uuid')
    $facts.add('hypervisor.cluster', $hypervisor.cluster)
    $facts.add('hypervisor.version', $hypervisor.version)
    $virtwho.hypervisors += @{
        name = $hypervisor.name
        uuid = $hypervisor.uuid
        facts = $facts
        guests = $guests
    }
}

Write-Host "Virt-who: Discovered $($virtwho.hypervisors.count) hosts with $($virtwho.hypervisors.guests.count) guests"
$virtwho | ConvertTo-Json -Depth 10 | Out-File -FilePath /etc/virt-who.d/virt-who.json
