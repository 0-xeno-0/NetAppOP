<#
.SYNOPSIS
    This script automates the complete provisioning of a new NetApp ONTAP SVM.
.DESCRIPTION
    It performs the following actions:
    1. Imports the DataONTAP module.
    2. Connects to a specified NetApp cluster.
    3. Creates a new Storage Virtual Machine (SVM).
    4. Creates a new FlexVol volume for the SVM.
    5. Creates a data Logical Interface (LIF) for network access.
    6. Creates a CIFS server and joins it to an Active Directory domain.
    7. Creates a CIFS share on the new volume.
    8. Takes an initial Snapshot of the new volume for protection.
    
    The script includes robust error handling for each major step and disconnects 
    from the cluster upon completion or failure.
.PARAMETER ClusterName
    The FQDN or IP address of the NetApp cluster's management interface.
.PARAMETER SvmName
    The name for the new SVM (e.g., "svm_finance").
.PARAMETER AggrName
    The name of the aggregate where the SVM root volume and data volume will be created.
.PARAMETER VolName
    The name for the new data volume (e.g., "finance_data").
.PARAMETER VolSize
    The size of the new data volume (e.g., "100g").
.PARAMETER LifName
    The name for the new data LIF (e.g., "svm_finance_cifs_lif1").
.PARAMETER LifIpAddress
    The static IP address for the new LIF.
.PARAMETER LifNetmask
    The subnet mask for the new LIF.
.PARAMETER LifHomeNode
    The node where the LIF will be created (e.g., "cluster-01").
.PARAMETER LifHomePort
    The physical or logical port for the LIF (e.g., "e0c").
.PARAMETER CifsServerName
    The NetBIOS name for the new CIFS server (e.g., "FINANCE-SMB").
.PARAMETER DomainName
    The FQDN of the Active Directory domain to join (e.g., "my.domain.com").
.EXAMPLE
    .\New-SvmProvisioner.ps1 -ClusterName "ontap-cluster.my.domain.com" -SvmName "svm_finance" `
    -AggrName "aggr1" -VolName "finance_data" -VolSize 100g -LifName "svm_finance_cifs_lif1" `
    -LifIpAddress "192.168.1.100" -LifNetmask "255.255.255.0" -LifHomeNode "cluster-01" `
    -LifHomePort "e0c" -CifsServerName "FINANCE-SMB" -DomainName "my.domain.com"

    This will prompt for cluster credentials and domain credentials, then provision the entire SVM.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(

    [Parameter(Mandatory=$false)]
    [switch]$Interactive,
    
    [Parameter()]
    [string]$ClusterName,

    [Parameter()]
    [string]$SvmName,

    [Parameter()]
    [string]$AggrName,

    [Parameter()]
    [string]$VolName,

    [Parameter()]
    [string]$VolSize,

    [Parameter()]
    [string]$LifName,

    [Parameter()]
    [string]$LifIpAddress,

    [Parameter()]
    [string]$LifNetmask,

    [Parameter()]
    [string]$LifHomeNode,

    [Parameter()]
    [string]$LifHomePort,

    [Parameter()]
    [string]$CifsServerName,

    [Parameter()]
    [string[]]$DnsServers,
    
    [Parameter()]
    [string]$DnsDomain = $DomainName,

    [Parameter()]
    [switch]$EnableNFS,
    
    [Parameter()]
    [string]$NfsRuleClient = "0.0.0.0/0",

    [Parameter()]
    [switch]$SetShareACL,
    
    [Parameter()]
    [string]$SharePermissionUser = "BUILTIN\Users",
    
    [Parameter()]
    [string]$SharePermissionLevel = "Change",

    [Parameter(Mandatory=$false)]
    [string]$OneLiner,

    [Parameter()]
    [string]$DomainName
)

# --- ONELINER PRE-CHECK ---
if ($PSBoundParameters.ContainsKey('OneLiner'))
{
    Write-Host "--- One-Liner Input Detected ---" -ForegroundColor Magenta
    Write-Host "Forcing Strict Mode and parsing input..." -ForegroundColor Blue
    
    # Force strict mode (disables all interactive prompts)
    $Interactive = $false
    
    # Split the single string by commas, and trim whitespace from each part
    $InputArray = $OneLiner.Split(',') | ForEach-Object { $_.Trim() }

    # Validate the count. Must be exactly 13 values.
    if ($InputArray.Count -ne 13) {
        Write-Error "Invalid One-Liner input. Expected exactly 13 comma-separated values." -ForegroundColor Red
        Write-Error "Received $($InputArray.Count) values." -ForegroundColor Red
        Write-Error "Expected order: ClusterName, SvmName, AggrName, VolName, VolSize, LifName, LifIpAddress, LifNetmask, LifHomeNode, LifHomePort, CifsServerName, DomainName, DnsServers" -ForegroundColor Red
        Write-Error "Note: For DnsServers, use a semi-colon (;) to separate multiple IPs (e.g., '8.8.8.8;1.1.1.1')" -ForegroundColor Red
        return # Exit script
    }

    # Map the array elements to the variables based on the user-defined order
    $ClusterName    = $InputArray[0]
    $SvmName        = $InputArray[1]
    $AggrName       = $InputArray[2]
    $VolName        = $InputArray[3]
    $VolSize        = $InputArray[4]
    $LifName        = $InputArray[5]
    $LifIpAddress   = $InputArray[6]
    $LifNetmask     = $InputArray[7]
    $LifHomeNode    = $InputArray[8]
    $LifHomePort    = $InputArray[9]
    $CifsServerName = $InputArray[10]
    $DomainName     = $InputArray[11]
    
    # The 13th item (index 12) is for DNS.
    # We split it by semi-colon to support multiple DNS servers in one field.
    $DnsServers     = $InputArray[12].Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    
    Write-Host "One-Liner parsed successfully." -ForegroundColor Green
    Write-Host "##--------------------------##" -ForegroundColor DarkMagenta
}
# --- END OF ONELINER PRE-CHECK ---

# --- MODULE 0: MODE SELECTION ---
# Check if *neither* -Interactive NOR -OneLiner was used
if ((-not $PSBoundParameters.ContainsKey('Interactive')) -and (-not $PSBoundParameters.ContainsKey('OneLiner'))) {
    Write-Host "--- Mode Selection ---" -ForegroundColor Magenta
    
    $Choice = ""
    # Loop until a valid choice is made (i, s, or empty for default)
    while ($Choice -notin @('i', 's', '')) {
        # ***FIXED***: Added prompt text to Read-Host
        $Choice = Read-Host "Run in (I)nteractive or (S)trict mode? [I/S] (Default: S)"
    }

    # --- Handle the choice ---
    
    if ($Choice -eq 'i') {
        $Interactive = $true
        Write-Host "Interactive mode selected." -ForegroundColor Green
    } 
    else {
        # Default to Strict if 's' or Enter is pressed
        $Interactive = $false
        Write-Host "Strict mode selected." -ForegroundColor Green
    }
    Write-Host "##--------------------------##" -ForegroundColor DarkMagenta
}
# --- END OF MODE SELECTION ---

# --- MODULE 0a: PARAMETER VALIDATION (Interactive Mode) ---
if ($Interactive) {
    Write-Host "--- SVM Provisioning Script (Interactive Mode) ---" -ForegroundColor Magenta

    # Check ClusterName
    if (-not $ClusterName) {
            Write-Host "Enter the NetApp Cluster FQDN or IP"  -ForegroundColor Yellow
            $ClusterName = Read-Host
        }

    # Check SvmName
    if (-not $SvmName) {
            Write-Host "Enter the name for the new SVM (e.g., svm_finance)"  -ForegroundColor Yellow
            $SvmName = Read-Host
        }

    # Check AggrName
    if (-not $AggrName) {
            # This will be checked again dynamically *after* connecting to the cluster
            Write-Host "Aggregate name not specified. Will prompt for selection after connecting." -ForegroundColor Blue
        }

     # Check VolName
    if (-not $VolName) {
            Write-Host "Enter the name for the new data Volume (e.g., finance_data)"  -ForegroundColor Yellow
            $VolName = Read-Host
        }

    # Check VolSize
    if (-not $VolSize) {
            Write-Host "Enter the size for the new Volume (e.g., 100g)"  -ForegroundColor Yellow
            $VolSize = Read-Host
        }

    # Check LifName
    if (-not $LifName) {
            Write-Host "Enter the name for the new data LIF (e.g., svm_finance_cifs_lif1)"  -ForegroundColor Yellow
            $LifName = Read-Host
        }

    # Check LifIpAddress
    if (-not $LifIpAddress) {
            Write-Host "Enter the static IP address for the LIF"  -ForegroundColor Yellow
            $LifIpAddress = Read-Host
        }

    # Check LifNetmask
    if (-not $LifNetmask) {
            Write-Host "Enter the subnet mask for the LIF (e.g., 255.255.255.0)"  -ForegroundColor Yellow
            $LifNetmask = Read-Host
        }

    # Check LifHomeNode
    if (-not $LifHomeNode) {
            # This will be checked again dynamically *after* connecting to the cluster
            Write-Host "LIF Home Node not specified. Will prompt for selection after connecting." -ForegroundColor Blue
        }

    # Check LifHomePort
    if (-not $LifHomePort) {
            Write-Host  "Enter the LIF's Home Port (e.g., e0c)"  -ForegroundColor Yellow    
            $LifHomePort = Read-Host
        }

    # Check CifsServerName
    if (-not $CifsServerName) {
            Write-Host "Enter the NetBIOS name for the CIFS server (e.g., FINANCE-SMB)"  -ForegroundColor Yellow
            $CifsServerName = Read-Host
        }

    # Check DomainName
    if (-not $DomainName) {
        Write-Host "Enter the Active Directory FQDN (e.g., my.domain.com)"  -ForegroundColor Yellow    
        $DomainName = Read-Host
        }

    # Check DnsServers
    if (-not $DnsServers) {
            # Read-Host can accept a comma-separated list which PowerShell turns into an array
            Write-Host "Enter the DNS Server IP(s), separated by commas"  -ForegroundColor Yellow
            $DnsServers = Read-Host
        }

    # Check DnsDomain
    if (-not $DnsDomain) {
            # $DnsDomain has a default, but we ask if it's still empty (if $DomainName was also empty)
            Write-Host "Enter the DNS search domain (e.g., my.domain.com)"  -ForegroundColor Yellow
            $DnsDomain = Read-Host
        }

    # Check EnableNFS
    if (-not $PSBoundParameters.ContainsKey('EnableNFS')) {
            Write-Host "(Optional) Enable NFS access for this SVM? (y/n)"  -ForegroundColor Yellow
            $Choice = Read-Host
            if ($Choice -eq 'y') {
                $EnableNFS = $true
            }
        }

    # If NFS is enabled, check the client rule
    if ($EnableNFS -and $NfsRuleClient -eq "0.0.0.0/0" -and -not $PSBoundParameters.ContainsKey('NfsRuleClient')) {
        Write-Host "(Optional) Enter the NFS client rule (e.g., 192.168.1.0/24, or press Enter for 'all')" -ForegroundColor Yellow
        $Rule = Read-Host
        if ($Rule) { # Only update if the user typed something
            $NfsRuleClient = $Rule
        }
    }

    # Check SetShareACL
    if (-not $PSBoundParameters.ContainsKey('SetShareACL')) {
        Write-Host "(Optional) Set default CIFS share permissions? (y/n)" -ForegroundColor Yellow
        $Choice = Read-Host
        if ($Choice -eq 'y') {
            $SetShareACL = $true
        }
    }

    # If setting ACLs, get the user and permission level
    if ($SetShareACL) {
        if (-not $PSBoundParameters.ContainsKey('SharePermissionUser')) {
            Write-Host "(Optional) Enter the User or Group for share ACL (Default: '$SharePermissionUser')" -ForegroundColor Yellow
            $User = Read-Host
            if ($User) { $SharePermissionUser = $User }
        }
        
        if (-not $PSBoundParameters.ContainsKey('SharePermissionLevel')) {
            Write-Host "(Optional) Enter Permission Level (e.g., Change, Read, FullControl) (Default: '$SharePermissionLevel')" -ForegroundColor Yellow
            $Level = Read-Host 
            if ($Level) { $SharePermissionLevel = $Level }
        }
    }

    Write-Host "Parameters loaded." -ForegroundColor Green
}
# --- END OF if ($Interactive) BLOCK ---

# --- MODULE 0b: STRICT MODE INPUT & VALIDATION ---
if (-not $Interactive) {
    Write-Host "--- SVM Provisioning Script (Strict Mode) ---" -ForegroundColor Magenta
    
    # If -OneLiner wasn't used, we're in the *interactive* Strict mode.
    if (-not $PSBoundParameters.ContainsKey('OneLiner')) {
        Write-Host "This mode requires for mandatory parameters only." -ForegroundColor Gray
        Write-Host "Optional features (NFS, Share ACLs) will be skipped." -ForegroundColor Blue
        Write-Host "##--------------------------##" -ForegroundColor DarkMagenta

        # --- Gather Mandatory Inputs ---
        
        # Check ClusterName
        if (-not $ClusterName) {
                Write-Host "Enter the NetApp Cluster FQDN or IP"  -ForegroundColor Yellow
                $ClusterName = Read-Host
            }

        # Check SvmName
        if (-not $SvmName) {
                Write-Host "Enter the name for the new SVM (e.g., svm_finance)"  -ForegroundColor Yellow
                $SvmName = Read-Host
            }

        # Check AggrName
        if (-not $AggrName) {
                Write-Host "Enter the name of the host Aggregate (e.g., aggr1)" -ForegroundColor Yellow
                $AggrName = Read-Host
            }

         # Check VolName
        if (-not $VolName) {
                Write-Host "Enter the name for the new data Volume (e.g., finance_data)"  -ForegroundColor Yellow
                $VolName = Read-Host
            }

        # Check VolSize
        if (-not $VolSize) {
                Write-Host "Enter the size for the new Volume (e.g., 100g)"  -ForegroundColor Yellow
                $VolSize = Read-Host
            }

        # Check LifName
        if (-not $LifName) {
                Write-Host "Enter the name for the new data LIF (e.g., svm_finance_cifs_lif1)"  -ForegroundColor Yellow
                $LifName = Read-Host
            }

        # Check LifIpAddress
        if (-not $LifIpAddress) {
                Write-Host "Enter the static IP address for the LIF"  -ForegroundColor Yellow
                $LifIpAddress = Read-Host
            }

        # Check LifNetmask
        if (-not $LifNetmask) {
                Write-Host "Enter the subnet mask for the LIF (e.g., 255.255.255.0)"  -ForegroundColor Yellow
                $LifNetmask = Read-Host
            }

        # Check LifHomeNode
        if (-not $LifHomeNode) {
                Write-Host "Enter the LIF's Home Node (e.g., cluster-01)" -ForegroundColor Yellow
                $LifHomeNode = Read-Host
            }

        # Check LifHomePort
        if (-not $LifHomePort) {
                Write-Host  "Enter the LIF's Home Port (e.g., e0c)"  -ForegroundColor Yellow    
                $LifHomePort = Read-Host
            }

        # Check CifsServerName
        if (-not $CifsServerName) {
                Write-Host "Enter the NetBIOS name for the CIFS server (e.g., FINANCE-SMB)"  -ForegroundColor Yellow
                $CifsServerName = Read-Host
            }

        # Check DomainName
        if (-not $DomainName) {
            Write-Host "Enter the Active Directory FQDN (e.g., my.domain.com)"  -ForegroundColor Yellow    
            $DomainName = Read-Host
            }

        # Check DnsServers
        if (-not $DnsServers) {
                Write-Host "Enter the DNS Server IP(s), separated by commas"  -ForegroundColor Yellow
                $DnsServers = Read-Host
            }

        # Check DnsDomain
        if (-not $DnsDomain) {
                Write-Host "Enter the DNS search domain (e.g., my.domain.com)"  -ForegroundColor Yellow
                $DnsDomain = Read-Host
            }
    }
        
    # --- Final Validation (for both OneLiner and interactive Strict) ---
    $MissingParams = @()
    if (-not $ClusterName) { $MissingParams += "ClusterName" }
    if (-not $SvmName) { $MissingParams += "SvmName" }
    if (-not $AggrName) { $MissingParams += "AggrName" }
    if (-not $VolName) { $MissingParams += "VolName" }
    if (-not $VolSize) { $MissingParams += "VolSize" }
    if (-not $LifName) { $MissingParams += "LifName" }
    if (-not $LifIpAddress) { $MissingParams += "LifIpAddress" }
    if (-not $LifNetmask) { $MissingParams += "LifNetmask" }
    if (-not $LifHomeNode) { $MissingParams += "LifHomeNode" }
    if (-not $LifHomePort) { $MissingParams += "LifHomePort" }
    if (-not $CifsServerName) { $MissingParams += "CifsServerName" }
    if (-not $DomainName) { $MissingParams += "DomainName" } 
    if (-not $DnsServers) { $MissingParams += "DnsServers" }

    if ($MissingParams.Count -gt 0) {
        Write-Error "Please enter the mandatory fields, correctly." -ForegroundColor Red
        Write-Error "The following parameters are still missing: $($MissingParams -join ', ')" -ForegroundColor Red
        return # Stop the script
    }
    Write-Host "All parameters loaded." -ForegroundColor Green
}
# --- END OF MODULE 0b ---

# --- MODULE 1: INSTALLATION AND CONNECTION ---

# Try to import the DataONTAP module.
Try {
    Write-Host "Importing DataONTAP module..." -ForegroundColor Blue
    Import-Module -Name DataONTAP -ErrorAction Stop
    Write-Host "Module imported successfully." -ForegroundColor Green
}
Catch {
    Write-Error "Failed to import DataONTAP module. Please ensure it is installed: 'Install-Module -Name DataONTAP'"
    # Stop the script if the module can't be loaded.
    return
}

# Define a variable to hold the connection for later use.
$ClusterConnection = $null

# Main Try block for the entire script's operations.
Try {
    # Get credentials to connect to the NetApp cluster.
    Write-Host "Please enter credentials for the NetApp cluster '$ClusterName'."
    $ClusterCredential = Get-Credential

    # Establish the connection to the controller.
    # We save the connection object to the $ClusterConnection variable.
    # -ErrorAction Stop ensures the 'Catch' block will trigger on failure.
    Write-Host "Connecting to cluster '$ClusterName'..." -ForegroundColor Blue
    $ClusterConnection = Connect-NcController -Name $ClusterName -Credential $ClusterCredential -ErrorAction Stop
    Write-Host "Successfully connected to $ClusterName." -ForegroundColor Green

    # --- MODULE 1b: DYNAMIC PARAMETER SELECTION ---
    if ($Interactive) {
        # If the user didn't specify an aggregate, let them choose one.
        if (-not $AggrName) {
            Write-Host "No aggregate specified. Querying cluster..." -ForegroundColor Blue
            try {
                # Get all aggregates and display them with a number
                $Aggregates = Get-NcAggr | Select-Object -Property Name, AvailableSize
                
                Write-Host "Please choose an aggregate:" -ForegroundColor Yellow
                for ($i = 0; $i -lt $Aggregates.Count; $i++) {
                    $Aggr = $Aggregates[$i]
                    # Format the available size to be more readable (e.g., "1.23 TB")
                    $SizeGB = [math]::Round($Aggr.AvailableSize / 1GB, 2)
                    Write-Host "  [$($i+1)] $($Aggr.Name) ($($SizeGB) GB available)" -ForegroundColor DarkGreen
                }
                
                # Prompt the user to pick a number
                $Choice = Read-Host "Enter your choice (number)"
                $AggrName = $Aggregates[$Choice - 1].Name
                
                Write-Host "You selected '$AggrName'." -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to get aggregate list. Error:$_" -ForegroundColor Red
                throw
            }
        }
        
        # If the user didn't specify a Home Node, let them choose one.
        if (-not $LifHomeNode) {
            Write-Host "No LIF Home Node specified. Querying cluster..." -ForegroundColor Gray
            try {
                Write-Host "Please choose a Home Node for the LIF:" -ForegroundColor Yellow
                $Nodes = Get-NcNode | Select-Object -Property Name, Health
                
                for ($i = 0; $i -lt $Nodes.Count; $i++) {
                    Write-Host "  [$($i+1)] $($Nodes[$i].Name) (Health: $($Nodes[$i].Health))"
                }
                
                $Choice = Read-Host "Enter your choice (number)"
                $LifHomeNode = $Nodes[$Choice - 1].Name
                Write-Host "You selected '$LifHomeNode'." -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to get node list. Error:$_" -ForegroundColor Red
                throw
            }
        }
    }


    # --- MODULE 2: CORE ONTAP RESOURCE MANAGEMENT (SVM & VOLUME) ---

    # Try block for SVM creation.
    Try {
        # --- PRE-FLIGHT CHECK ---
        $SvmExists = Get-NcVserver -Name $SvmName -ErrorAction SilentlyContinue
        
        if ($SvmExists) {
            Write-Warning "SVM '$SvmName' already exists. Skipping creation." -ForegroundColor DarkRed
        }
        else {
            # --- CREATE SVM ---
            Write-Host "Creating SVM '$SvmName'..."
            if ($PSCmdlet.ShouldProcess($SvmName, "Create SVM")) {
                # Creates the new SVM with its root volume on the specified aggregate.
                New-NcVserver -Name $SvmName -RootVolume ($SvmName + "_root") -AggrList $AggrName -RootVolumeSecurityStyle "ntfs" -ErrorAction Stop
                Write-Host "SVM '$SvmName' created successfully." -ForegroundColor Green
            }
        }
    }
    Catch {
        Write-Error "Failed to create SVM '$SvmName'. Error: $_" -ForegroundColor Red
        throw
    }

    # Try block for SVM DNS CONFIGURATION.
    Try {
        Write-Host "Configuring DNS for SVM '$SvmName'..."
        if ($PSCmdlet.ShouldProcess($SvmName, "Configure DNS")) {
            # This applies the DNS settings we collected in Module 0
            New-NcDns -Vserver $SvmName -Domains $DnsDomain -Servers $DnsServers -ErrorAction Stop
            Write-Host "DNS configured successfully for SVM '$SvmName'." -ForegroundColor Green
        }
    }
    Catch {
        Write-Error "Failed to configure DNS. This will likely cause the Domain Join to fail. Error:$_" -ForegroundColor Red
        throw
    }

    # Try block for Volume creation.
    Try {
        # --- PRE-FLIGHT CHECK ---
        $VolExists = Get-NcVol -Vserver $SvmName -Name $VolName -ErrorAction SilentlyContinue

        if ($VolExists) {
            Write-Warning "Volume '$VolName' on SVM '$SvmName' already exists. Skipping creation." -ForegroundColor DarkRed
        }
        else {
            # --- CREATE VOLUME ---
            Write-Host "Creating volume '$VolName'..." -ForegroundColor DarkGreen
            if ($PSCmdlet.ShouldProcess($VolName, "Create Volume")) {
                # Creates the new data volume.
                New-NcVol -Name $VolName -Vserver $SvmName -Aggr $AggrName -Size $VolSize -SpaceReserve "none" -ErrorAction Stop
                Write-Host "Volume '$VolName' created successfully." -ForegroundColor Green
            }
        }
    }
    Catch {
        Write-Error "Failed to create volume '$VolName'. Error: $_" -ForegroundColor Red
        throw
    }

    # --- MODULE 3: NETWORK AND PROTOCOL CONFIGURATION (LIF & CIFS) ---

    # Try block for LIF creation.
    Try {
        # --- PRE-FLIGHT CHECK ---
        $LifExists = Get-NcLif -Vserver $SvmName -Name $LifName -ErrorAction SilentlyContinue
        
        if ($LifExists) {
            Write-Warning "LIF '$LifName' on SVM '$SvmName' already exists. Skipping creation." -ForegroundColor DarkRed
        }
        else {
            # --- CREATE LIF ---
            Write-Host "Creating LIF '$LifName'..." -ForegroundColor Blue
            if ($PSCmdlet.ShouldProcess($LifName, "Create LIF")) {
                
                # Define the list of protocols for the LIF
                $Protocols = @("cifs")
                if ($EnableNFS) {
                    $Protocols += "nfs"
                    Write-Host "LIF will be enabled for CIFS and NFS." -ForegroundColor Blue
                }
                
                # Creates the Logical Interface (IP address)
                New-NcLif -Name $LifName -Vserver $SvmName -Address $LifIpAddress -Netmask $LifNetmask -HomeNode $LifHomeNode -HomePort $LifHomePort -DataProtocol $Protocols -ErrorAction Stop
                Write-Host "LIF '$LifName' created successfully." -ForegroundColor Green
            }
        }
    }
    Catch {
        Write-Error "Failed to create LIF '$LifName'. Error: $_" -ForegroundColor Red
        throw
    }

    # Try block for CIFS Server creation.
    Try {
        # --- PRE-FLIGHT CHECK ---
        $CifsExists = Get-NcCifsServer -Vserver $SvmName -ErrorAction SilentlyContinue
        
        if ($CifsExists) {
            Write-Warning "CIFS server already exists on SVM '$SvmName'. Skipping creation." -ForegroundColor DarkRed
        }
        else {
            # --- CREATE CIFS SERVER ---
            Write-Host "Creating CIFS server '$CifsServerName' and joining domain '$DomainName'..." -ForegroundColor Blue
            Write-Host "Please enter DOMAIN credentials (with rights to join) for '$DomainName'." -ForegroundColor Blue
            $DomainCredential = Get-Credential

            if ($PSCmdlet.ShouldProcess($CifsServerName, "Create CIFS Server")) {
                # Creates the CIFS server on the SVM and joins it to the AD domain.
                New-NcCifsServer -Vserver $SvmName -CifsServer $CifsServerName -Domain $DomainName -Credential $DomainCredential -ErrorAction Stop
                Write-Host "CIFS server '$CifsServerName' created and joined to domain." -ForegroundColor Green
            }
        }
    }
    Catch {
        Write-Error "Failed to create CIFS server '$CifsServerName'. Error: $_" -ForegroundColor Red
        throw
    }

    # Try block for CIFS Share creation.
    Try {
        # --- PRE-FLIGHT CHECK ---
        $ShareExists = Get-NcCifsShare -Vserver $SvmName -Name "data" -ErrorAction SilentlyContinue

        if ($ShareExists) {
            Write-Warning "CIFS share 'data' on SVM '$SvmName' already exists. Skipping creation." -ForegroundColor DarkRed
        }
        else {
            # --- CREATE CIFS SHARE ---
            $SharePath = "/" + $VolName
            Write-Host "Creating CIFS share 'data' on path '$SharePath'..." -ForegroundColor Blue
            if ($PSCmdlet.ShouldProcess("data", "Create CIFS Share")) {
                # Creates the actual share that users will connect to.
                New-NcCifsShare -Name "data" -Vserver $SvmName -Path $SharePath -ShareProperty "oplocks", "change_notify" -ErrorAction Stop
                Write-Host "CIFS share 'data' created successfully. Path: \\$CifsServerName\data" -ForegroundColor Green
            }
        }
    }
    Catch {
        Write-Error "Failed to create CIFS share. Error: $_" -ForegroundColor Red
        throw
    }

    # --- MODULE 3a: CIFS SHARE PERMISSIONS (ACLs) ---
    if ($SetShareACL) {
        Try {
            Write-Host "Setting '$SharePermissionLevel' for '$SharePermissionUser' on share 'data'..." -ForegroundColor Blue
            if ($PSCmdlet.ShouldProcess("data", "Add CIFS Share ACL")) {
                
                # Adds the access control entry to the share
                Add-NcCifsShareAcl -Vserver $SvmName -ShareName "data" -UserOrGroup $SharePermissionUser -Permission $SharePermissionLevel -ErrorAction Stop
                
                Write-Host "Share permissions set successfully." -ForegroundColor Green
            }
        }
        Catch {
            Write-Warning "Failed to set share permissions. Error:$_" -ForegroundColor DarkRed
            # We use Write-Warning as the share was still created.
        }
    }

    # --- MODULE 3b: NFS CONFIGURATION ---
    if ($EnableNFS) {
        Write-Host "##--------------------------##" -ForegroundColor DarkMagenta
        Write-Host "Configuring NFS Server..." -ForegroundColor Blue
        Try {
            if ($PSCmdlet.ShouldProcess($SvmName, "Enable NFS Server")) {
                
                # 1. Enable NFS server on the SVM
                Write-Host "Enabling NFS service on SVM '$SvmName'..." -ForegroundColor DarkGreen
                New-NcNfsServer -Vserver $SvmName -ErrorAction Stop
                
                # 2. Create a new export policy for the volume
                $PolicyName = $VolName + "_policy"
                Write-Host "Creating export policy '$PolicyName'..." -ForegroundColor DarkGreen
                New-NcExportPolicy -Vserver $SvmName -PolicyName $PolicyName -ErrorAction Stop
                
                # 3. Add a rule to the policy to allow access
                Write-Host "Adding rule for '$NfsRuleClient' to policy..." -ForegroundColor DarkGreen
                Add-NcExportRule -Vserver $SvmName -PolicyName $PolicyName -ClientMatch $NfsRuleClient -Protocol "nfs" -ReadOnlyRule "any" -ReadWriteRule "any" -SuperUserRule "any" -ErrorAction Stop
                
                # 4. Apply the policy to the data volume
                Write-Host "Applying policy to volume '$VolName'..." -ForegroundColor DarkGreen
                Set-NcVol -Vserver $SvmName -Name $VolName -ExportPolicy $PolicyName -ErrorAction Stop
                
                Write-Host "NFS enabled and export policy '$PolicyName' applied successfully." -ForegroundColor Green
            }
        }
        Catch {
            # We use Write-Warning here because the CIFS part might have succeeded
            Write-Warning "Failed to configure NFS. Error:$_" -ForegroundColor DarkRed
        }
    }

    # --- MODULE 4: DATA PROTECTION (SNAPSHOT) ---
    
    # Try block for Snapshot creation.
    Try {
        $SnapshotName = "initial_provision"
        Write-Host "Creating initial Snapshot '$SnapshotName' for volume '$VolName'..." -ForegroundColor Blue
        if ($PSCmdlet.ShouldProcess($VolName, "Create Snapshot")) {
            # Creates a point-in-time Snapshot of the volume.
            New-NcSnapshot -Volume $VolName -Vserver $SvmName -Name $SnapshotName -ErrorAction Stop
            Write-Host "Snapshot '$SnapshotName' created successfully." -ForegroundColor Green
        }
    }
    Catch {
        # A Snapshot failure is not critical, so we use Write-Warning instead of Write-Error.
        Write-Warning "Failed to create initial Snapshot. Error:$_" -ForegroundColor DarkRed
    }

    # --- MODULE 5: REPORTING ---
    
    # Final success report.
    # ***FIXED***: Removed duplicate -ForegroundColor parameter
    Write-Host "##--------------------------##" -ForegroundColor DarkMagenta
    Write-Host "PROVISIONING COMPLETE" -ForegroundColor DarkCyan
    # ***FIXED***: Removed duplicate -ForegroundColor parameter
    Write-Host "##--------------------------##" -ForegroundColor DarkMagenta
    Write-Host "SVM:        $SvmName" -ForegroundColor Blue
    Write-Host "Volume:     $VolName ($VolSize)" -ForegroundColor Blue
    Write-Host "Share Path: \\$CifsServerName\data" -ForegroundColor Blue
    Write-Host "LIF IP:     $LifIpAddress" -ForegroundColor Blue
    if ($EnableNFS) {
        # Corrected NFS path to include the root slash
        Write-Host "NFS Path:   ${LifIpAddress}:/${VolName}" -ForegroundColor DarkGreen
    }
    Write-Host "##--------------------------##" -ForegroundColor DarkMagenta

}
Catch {
    # This is the 'Catch' for the main Try block. It catches any error that was "thrown".
    Write-Error "A critical error occurred during provisioning. Script aborted."  -ForegroundColor Red
    Write-Error $_.Exception.Message
}
Finally {
    # The 'Finally' block ALWAYS runs, whether the script succeeded or failed.
    # This is the best practice for cleanup, like disconnecting.
    if ($ClusterConnection) {
        Write-Host "Disconnecting from cluster '$ClusterName'..." -ForegroundColor Blue
        # Disconnects the session using the connection object we saved earlier.
        Remove-NcController -Controller $ClusterConnection
        Write-Host "Disconnected." -ForegroundColor DarkRed
    }
}
