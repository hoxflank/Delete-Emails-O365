# File: Delete-Emails.ps1
# Purpose: this script will connect to the Office 365 Security & Compliance
# Center and will allow admins to delete specified emails from every mailbox
# in the organization.
# Author: Jonathan Gregson <jonathan.gregson@agsstainless.com>
#                          <jdgregson@gmail.com>

param (
    [int]$timeout = "120"
 )

# check if we are on PowerShell version 5 and warn the user if not
if($PSVersionTable.PSVersion.Major -lt 5) {
    $warning = @"
    ================================ /!\ ================================
    WARNING: Your version of PowerShell is less than V5. This script may
    not run properly in your version. If you run into issues, please
    install this Windows update to bring your PowerShell version to V5:
    https://www.microsoft.com/en-us/download/details.aspx?id=50395
    =====================================================================
"@
    Write-Host $warning -ForegroundColor Yellow
}

function ColorMatch {
    #https://stackoverflow.com/questions/12609760
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string] $InputObject,

        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Pattern,

        [Parameter(Mandatory = $false, Position = 1)]
        [string] $Color='Red'
    )
    begin{ $r = [regex]$Pattern }
    process {
        $ms = $r.matches($inputObject)
        $startIndex = 0
        foreach($m in $ms) {
            $nonMatchLength = $m.Index - $startIndex
            Write-Host $inputObject.Substring($startIndex, $nonMatchLength) -NoNew
            Write-Host $m.Value -Fore $Color -NoNew
            $startIndex = $m.Index + $m.Length
        }
        if($startIndex -lt $inputObject.Length) {
            Write-Host $inputObject.Substring($startIndex) -NoNew
        }
        Write-Host
    }
}

function New-GUID() {
    $guid = [guid]::NewGuid().Guid.Replace("-", "").Substring(25)
    Return "delete-emails-$guid"
}

function Delete-Search($guid) {
    Remove-ComplianceSearch -Identity "$guid" -Confirm:$false
}

function Clean-Exit($message) {
    if($message) {Write-Host $message}
    Delete-Search "$guid"
    Exit
}

function Get-ComplianceSearchResults($guid) {
    $results = (Get-ComplianceSearch $guid).SuccessResults
    $results = $results -replace "{" -replace "}" -replace "`r`n"
    $results = $results -replace "(, Total size: [0-9,]*)","`r`n"
    $results = $results -split "`r`n"
    Return $results
}

function Get-ComplianceSearchResultsUsers($guid) {
    $results = Get-ComplianceSearchResults $guid
    $usersWithResults = @()
    $pattern = "Location: (.*?), Item count: [0-9]?"
    foreach($mailbox in $results) {
        if([int]($mailbox.Split(' ')[4]) -gt 0) {
            $usersWithResults += [regex]::match($mailbox, $pattern).Groups[1].Value
        }
    }
    Return $usersWithResults
}

function Get-ComplianceSearchResultsList($guid) {
    $results = Get-ComplianceSearchResults $guid
    foreach($mailbox in $results) {
        if([int]($mailbox.Split(' ')[4]) -gt 0) {
            "$mailbox" | ColorMatch "Item count: [0-9]*"
        }
    }
}

function Test-ComplianceSearchComplete($guid) {
    $theSearch = Get-ComplianceSearch -Identity "$guid" | Format-List -Property Status | Out-String
    $searchProgress = $theSearch | Select-String -pattern "Completed"
    if($searchProgress.length -gt 0) {
        Return $true
    } else {
        Return $false
    }
}

# connect to Exchange Online PowerShell
if(-not($global:EOSession) -or($global:EOSession.State -ne "Opened") -or($global:EOSession.Availability -ne "Available")) {
    $o365creds = Get-Credential -Message "Enter your Exchange Online admin credentials"
    $global:EOSession = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://ps.outlook.com/powershell-liveid/ -Credential $o365creds -Authentication Basic -AllowRedirection
    $out = Import-PSSession $global:EOSession -AllowClobber -DisableNameChecking|Out-String
    if($out -like "*ExportedCommands*") {Write-Host "Successfully connected to Exchange Online"}
}
# connect to Security and Compliance Center PowerShell
if(-not($global:SCCSession) -or($global:SCCSession.State -ne "Opened") -or($global:SCCSession.Availability -ne "Available")) {
    if(-not($o365creds)) {$o365creds = Get-Credential -Message "Enter your Office 365 admin credentials"}
    $global:SCCSession = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://ps.compliance.protection.outlook.com/powershell-liveid -Credential $o365creds -Authentication Basic -AllowRedirection
    $out = Import-PSSession $global:SCCSession -AllowClobber -DisableNameChecking|Out-String
    if($out -like "*ExportedCommands*") {Write-Host "Successfully connected to Security and Compliance Center"}
}
# nullify our creds so they aren't accessible anymore
$o365creds = $Null

$examples =
'Example: sent>=07/03/2017 AND sent<=07/05/2017 AND subject:"open this attachment!"',
'Example: subject:"contains this phrase" from:somedomain.com',
'Example: to:user@mycompany.com',
'Example: from:some.spammer@hijackeddomain.com',
'Example: attachment:"Malicious-File.docx"',
'Example: attachment:"docx" NOT from:user@mycompany.com',
'More: https://technet.microsoft.com/en-us/library/ms.exch.eac.searchquerylearnmore(v=exchg.150).aspx'

# get the search criteria from the user
while($true) {
    if($search -and $search.ToUpper() -eq 'M') {
        $examples
    } elseif($search) {
        $search = "kind:email $search"
        break
    } else {
        Write-Host "Enter a search string to locate the email(s)"
        Write-Host $examples[0]
    }
    $search = Read-Host "(enter `"M`" for more examples) Search"
}

# create and run the search
$guid = New-GUID
$out = New-ComplianceSearch -Name $guid -ExchangeLocation all -ContentMatchQuery "$search" | Out-String
Write-Host "Starting the search..."
Start-ComplianceSearch $guid

# wait for the results and ask the user if they look right
$searchCompleted = $false
$usersWithResults = @()
for($i=0; $i -le $timeout; $i++) {
    if(Test-ComplianceSearchComplete($guid)) {
        $searchCompleted = $true
        Write-Host "Search complete"
        Write-Host "The search returned the following:"
        Get-ComplianceSearch $guid | Format-List -Property Items
        if((Get-ComplianceSearch $guid).Items -eq 0) {
            Clean-Exit "0 items found. Cleaning up and exiting..."
        }
        $usersWithResults = Get-ComplianceSearchResultsUsers $guid
        Write-Host "Does this seem accurate?"
        $answer = Read-Host "[Y] Yes  [N] No  [M] More details  (default is `"N`")"
        if($answer.ToUpper() -eq "Y") {
            Write-Host "Confirmed. Continuing to delete..."
            break
        } elseif($answer.ToUpper() -eq "M") {
            Get-ComplianceSearchResultsList $guid
            continue;
        } else {
            Clean-Exit "Canceled. Cleaning up and exiting..."
        }
    }
    Sleep 1
}
if($searchCompleted -eq $false) {
    "Error: the search timed out" | ColorMatch .
    "Try running this script with a longer timeout, e.g:" | ColorMatch .
    "    Delete-Emails -Timeout 6000" | ColorMatch .
    Clean-Exit
}

# delete the emails with the user's confirmation
$out = New-ComplianceSearchAction -SearchName "$guid" -Purge -PurgeType SoftDelete | Out-String
$ComplianceSearchActions = Get-ComplianceSearchAction | Out-String
$purgeProgress = $ComplianceSearchActions | Select-String -Pattern $guid
# if the user did not confirm then exit
if($purgeProgress.length -eq 0) {
    Clean-Exit "The purge was canceled. Cleaning up and exiting..."
}

# wait for the deletion results and delete the search if it is finished
for($i=0; $i -le $timeout; $i++) {
    $thePurge = Get-ComplianceSearchAction -Identity $guid"_Purge" | Out-String
    $purgeProgress = $thePurge | Select-String -Pattern "Completed"
    if($purgeProgress.length -gt 0) {
        Write-Host "Deletion complete"
        Delete-Search "$guid"
        Break
    }
    Sleep 1
}

$confMessage = "Would you like to confirm the deletion? This will start many searches and may take a while."
$confMessage = "$confMessage`n[Y] Yes  [N] No  (default is `"N`")"
if(-not((Read-Host $confMessage).ToUpper() -eq "Y")) {
    Write-Host "Skipping confirmation"
    Clean-Exit
}
# for each mailbox with results, create a search query which will exclude
# deleted items folders
# see: https://support.office.com/en-us/article/e3cbc79c-5e97-43d3-8371-9fbc398cd92e
Write-Host "Confirming deletion..."
$PendingDeletions = New-Object System.Collections.ArrayList(,@($usersWithResults))
$ConfirmationSearches = New-Object System.Collections.ArrayList
for($i=0; $i -lt $PendingDeletions.Count; $i++) {
    $UserEmail = $PendingDeletions[$i]
    $folderExclusionsQuery = " AND NOT ("
    $excludeFolders = "/Deletions","/Purges","/Recoverable Items"
    $folderStatistics = Get-MailboxFolderStatistics $UserEmail
    foreach($folderStatistic in $folderStatistics) {
        $folderPath = $folderStatistic.FolderPath;
        if($excludeFolders.Contains($folderPath)) {
            $folderId = $folderStatistic.FolderId;
            $encoding= [System.Text.Encoding]::GetEncoding("us-ascii")
            $nibbler= $encoding.GetBytes("0123456789ABCDEF");
            $folderIdBytes = [Convert]::FromBase64String($folderId);
            $indexIdBytes = New-Object byte[] 48;
            $indexIdIdx=0;
            $folderIdBytes | select -skip 23 -First 24 | %{$indexIdBytes[$indexIdIdx++]=$nibbler[$_ -shr 4];$indexIdBytes[$indexIdIdx++]=$nibbler[$_ -band 0xF]}
            $folderQuery = "folderid:$($encoding.GetString($indexIdBytes))";
            $folderExclusionsQuery += "($folderQuery) OR "
        }
    }
    $folderExclusionsQuery += ")"
    $fullSearch = "$UserEmail#$search $folderExclusionsQuery"
    $PendingDeletions[$i] = $fullSearch
}

$MailboxesWithResults = $PendingDeletions.Count
while($PendingDeletions.Count -gt 0) {
    foreach($PendingDeletion in $PendingDeletions) {
        $PendingDeletion = $PendingDeletion -Split '#'
        $thisGuid = New-GUID
        $out = New-ComplianceSearch -Name "$thisGuid" -ExchangeLocation $PendingDeletion[0] -ContentMatchQuery "$($PendingDeletion[1])" | Out-String
        Start-ComplianceSearch -Identity "$thisGuid"
        [void]$ConfirmationSearches.Add($thisGuid)
    }
    while($ConfirmationSearches.Count -gt 0) {
        for($i=0; $i -lt $ConfirmationSearches.Count; $i++) {
            $thisSearch = $ConfirmationSearches[$i];
            if(Test-ComplianceSearchComplete("$thisSearch")) {
                $results = Get-ComplianceSearchResults "$thisSearch";
                $thisQuery = (Get-ComplianceSearch $thisSearch).ContentMatchQuery
                $thisUser = (Get-ComplianceSearch $thisSearch).ExchangeLocation
                $ConfirmationSearches.Remove($thisSearch)
                Delete-Search "$thisSearch"
                foreach($mailbox in $results) {
                    if($mailbox -and [int]($mailbox.Split(' ')[4]) -eq 0) {
                        $PendingDeletions.Remove("$thisUser#$thisQuery")
                        $Progress = "($($MailboxesWithResults-$PendingDeletions.Count)/$MailboxesWithResults)"
                        "$Progress $mailbox" -replace('Location: ') | ColorMatch "Item count: [0-9]*" -Color 'Green'
                    }
                }
            }
        }
        sleep 0.5
    }
}
