# NetApp ONTAP SVM Provisioning Script

A robust PowerShell script to automate the complete, end-to-end provisioning of a NetApp ONTAP Storage Virtual Machine (SVM). This script handles the creation of the SVM, its root volume, a data volume, a data LIF, DNS configuration, and the creation of a CIFS server and share, including the Active Directory domain join.

Designed for both flexibility and automation, it features multiple execution modes to suit any user, from a fully-guided interactive session to a single-line command for full automation.

## Features

* **End-to-End Automation:** Provisions a complete, file-services-ready SVM from a single script.
* **Flexible Execution Modes:**
    * **Full Interactive Mode:** Guides the user step-by-step, asking for all parameters and optional features (like NFS and Share ACLs).
    * **Guided Strict Mode:** Prompts the user for *only* the 13 mandatory parameters.
    * **One-Liner Mode:** Allows all 13 mandatory parameters to be passed in a single string for 100% automation.
* **Idempotent & Safe:** Uses pre-flight checks to see if resources (SVM, Volume, LIF, Share) already exist, skipping them if they do.
* **Robust Error Handling:** Each major provisioning step is wrapped in a `Try/Catch` block to provide clear error messages.
* **-WhatIf Support:** Natively supports the `-WhatIf` common parameter to see what changes *would* be made without executing them.
* **Optional Protocols:** Configures CIFS by default and includes optional, interactive prompts to also configure NFS access on the new volume.
* **Cleanup:** Automatically and safely disconnects from the cluster on success or failure.

## Requirements

* PowerShell 5.1 or later (Windows PowerShell or PowerShell 7+).
* The NetApp DataONTAP PowerShell Toolkit.
    * `Install-Module -Name DataONTAP -Scope CurrentUser`
* **NetApp Cluster Credentials:** A user with rights to create SVMs, volumes, etc.
* **Active Directory Credentials:** A user with rights to join a computer to the domain (required for CIFS setup).

## Script Usage

The script offers three distinct ways to run, managed by an initial prompt or command-line parameters.

---

### 1. Full Interactive Mode

This mode is for users who want to be guided through every option, including optional settings like NFS and CIFS Share ACLs.

**How to run:**
1.  Execute the script with no parameters: `.\NetOntap.ps1`
2.  At the prompt, type `i` and press Enter.

```powershell
PS C:\> .\NetOntap.ps1

--- Mode Selection ---
Run in (I)nteractive or (S)trict mode? [I/S] (Default: S)
i
Interactive mode selected.
---
--- SVM Provisioning Script (Interactive Mode) ---
Enter the NetApp Cluster FQDN or IP: [cluster-name]
...
```


### 2. Guided Strict Mode
This mode is for users who want to quickly provide only the mandatory parameters and skip all optional settings.

**How to run:**

Execute the script with no parameters: .\NetOntap.ps1

At the prompt, type s (or just press Enter, as it's the default).

```powershell
PS C:\> .\NetOntap.ps1

--- Mode Selection ---
Run in (I)nteractive or (S)trict mode? [I/S] (Default: S)
s
Strict mode selected.
---
--- SVM Provisioning Script (Strict Mode) ---
This mode requires for mandatory parameters only.
...
Enter the NetApp Cluster FQDN or IP: [cluster-name]
...
```

### 3. One-Liner Mode (Full Automation)
This mode is for power users or automation workflows. It uses the -OneLiner parameter to pass all 13 mandatory values in a single, comma-separated string. This mode skips all prompts.

**How to run: Execute the script using the -OneLiner parameter with a quoted string.**
```powershell
.\NetOntap.ps1 -OneLiner "ontap-cluster.corp.local, svm_sales, aggr_node01_sas, sales_data, 250g, svm_sales_cifs_lif1, 192.168.10.50, 255.255.255.0, ontap-cluster-01, e0d, SALES-SMB, corp.local, 192.168.10.5;192.168.10.6"
```

**One-Liner Value Order (MUST be in this order):The string must contain exactly 13 values, separated by commas.**
ClusterName: ontap-cluster.corp.local
SvmName: svm_sales
AggrName: aggr_node01_sas
VolName: sales_data
VolSize: 250g
LifName: svm_sales_cifs_lif1
LifIpAddress: 192.168.10.50
LifNetmask: 255.255.255.0
LifHomeNode: ontap-cluster-01
LifHomePort: e0d
CifsServerName: SALES-SMB
DomainName: corp.local
DnsServers: 192.168.10.5;192.168.10.6
Note: For multiple DNS servers, separate them with a semi-colon (;) inside the string.

 | Parameter | Description | Example |
 | :---: | :---: | :---:|
 | $ClusterName | FQDN or IP of the NetApp cluster management interface. | ontap.my.domain.com |
 | $SvmName | The name for the new SVM. | svm_finance |
 | $AggrName | The aggregate to host the SVM root and data volumes. | aggr1 |
 | $VolName | The name for the new data volume. | finance_data |
 | $VolSize | The size of the new data volume. | 100g |
 | $LifName | The name for the new data LIF. | svm_finance_cifs_lif1 |
 | $LifIpAddress | The static IP address for the new LIF. | 192.168.1.100 |
 | $LifNetmask | The subnet mask for the new LIF. | 255.255.255.0 |
 | $LifHomeNode | The node where the LIF will be created. | cluster-01 |
 | $LifHomePort | The physical or logical port for the LIF. | e0c |
 | $CifsServerName | The NetBIOS name for the new CIFS server. | FINANCE-SMB |
 | $DomainName | The FQDN of the Active Directory domain to join. | my.domain.com |
 | $DnsServers | [Array] One or more DNS server IPs for the SVM. | 192.168.1.5 |
 | $DnsDomain | The DNS search domain for the SVM. | my.domain.com |


**Optional Parameters (Interactive Mode Only)**
These parameters can be provided on the command line, or the script will prompt for them if running in Full Interactive Mode.

[switch]$EnableNFS: If present, prompts to configure NFS access on the volume.

[string]$NfsRuleClient: The client spec for the NFS export rule (Default: 0.0.0.0/0).

[switch]$SetShareACL: If present, prompts to set permissions on the new CIFS share.

[string]$SharePermissionUser: The user/group for the share ACL (Default: BUILTIN\Users).

[string]$SharePermissionLevel: The permission level to grant (Default: Change).

**Automation Parameters**
[switch]$Interactive: Forces the script to run in Full Interactive Mode and skip the initial mode selection prompt.

[string]$OneLiner: Provides all 13 mandatory parameters in a single string, forcing Strict Mode and skipping all prompts.
