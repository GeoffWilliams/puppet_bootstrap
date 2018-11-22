#<#
#.Synopsis
#   Bootstrap Puppet Agent from Enterprise Master
#.Description
#   Register a node with Puppet Enterprise based on VMWare tags or user
#   Inteview.
#.Parameter Debug
#   Enable debug mode
#.Parameter VmName
#   VM Name to lookup in VCenter
#.Parameter NoHosts
#   Dont add puppet master to hosts file
#.Parameter Force
#   Force installation when no tags found
#.Parameter Interactive
#   Ignore VCenter and enter tags manually
#.Parameter DryRun
#   Dont install puppet (for debugging)
#.Parameter Certname
#   Name of this node in Puppet (defaults to FQDN)
#.Example
#   # Register automatically using VMWare
#	  ./puppet_bootstrap.ps1
#.Example
#   # Register based on user interview
#	  ./puppet_bootstrap.ps1 --interview
##>
param(
    [Switch] $Debug = $false,
    [String] $VmName = [System.Net.Dns]::GetHostByName($env:computerName).HostName,
    [Switch] $NoHosts = $false,
    [Switch] $Force = $false,
    [Switch] $Interactive = $false,
    [Switch] $DryRun = $false,
    [Switch] $Verbose = $false,
    [string] $Certname = [System.Net.Dns]::GetHostByName($env:computerName).HostName
)

# full path to expected config file
$CONFIG_FILE = "c:\ProgramData\puppet_bootstrap\puppet_bootstrap.cfg"

# config file section for VCenter and Puppet info
$CONFIG_SECT = "main"

# config file section for interactive mode menu
$MENU_SECT = "menu"

# value user can select to skip answering a question in interview mode
$INTERVIEW_SKIP = "nothing"

# Tag pattern used in VCenter
$PP_REGEX = 'pp_.+'

# We must disable SSL validation to be able to talk to the VMWare REST API
# See also:
# * https://stackoverflow.com/a/46067121/3441106
# * http://huddledmasses.org/blog/validating-self-signed-certificates-properly-from-powershell/
# Powershell 6 brings us `-SkipCertificateCheck` option for invoke-webrequest but its not avaiable
# in windows 10, 2012 or 2016 out of the box...
function disableSSlValidation() {
    # custom .Net callback from stackoverflow link - you can't use the `$true` trick here or you
    # get an error about not having a default runspace.
    add-type -TypeDefinition @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class Dummy {
    public static bool ReturnTrue(object sender,
        X509Certificate certificate,
        X509Chain chain,
        SslPolicyErrors sslPolicyErrors) { return true; }

    public static RemoteCertificateValidationCallback GetDelegate() {
        return new RemoteCertificateValidationCallback(Dummy.ReturnTrue);
    }
}
"@
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [dummy]::GetDelegate()

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# Return a section from our ini file
# No native inifile support in powershel so use script from
# https://blogs.technet.microsoft.com/heyscriptingguy/2011/08/20/use-powershell-to-work-with-any-ini-file/
function Get-IniContent ($filePath, $sect)
{
    $ini = @{}
    switch -regex -file $FilePath
    {
        "^\[(.+)\]" # Section
        {
            $section = $matches[1]
            $ini[$section] = @{}
            $CommentCount = 0
        }
        "^(;.*)$" # Comment
        {
            $value = $matches[1]
            $CommentCount = $CommentCount + 1
            $name = "Comment" + $CommentCount
            $ini[$section][$name] = $value
        }
        "(.+?)\s*=(.*)" # Key
        {
            $name,$value = $matches[1..2]
            $ini[$section][$name] = $value.trim()
        }
    }
    if (-not $ini.ContainsKey($sect)) {
        fatal "Section $($sect) missing from config file at $($FilePath)"
    }

    return $ini[$sect]
}



function fatal ($message) {
    write-error($message)
    exit 1
}

# Load site-specific details for Puppet/VCenter
function loadConfig($sect) {
    $conf = @{}
    if (test-path $CONFIG_FILE) {
        $conf = Get-IniContent $CONFIG_FILE $sect
    } else {
        fatal "Missing config file at $($CONFIG_FILE)"
    }
    return $conf
}

# proceed to install puppet
function installPuppet ($conf, $dryRun, $tags, $finalCertname) {

    # dump current settings and give chance to abort
    outputSettings $tags $finalCertname
    write-host "CTRL+C now if incorrect!"
    sleep 2

    # build the list of extensions
    $pp_ext = ""
    foreach ($key in $tags.keys) {
        $name = $key
        $value = $tags[$key]

        $pp_ext += "extension_requests:$($name)=$($value) "
    }
    $agent_certname = "agent:certname=$($finalCertname)"

    $tempFile = [System.IO.Path]::GetTempFileName() + ".ps1"
    $url = "https://$($conf['puppet_master_host']):8140/packages/current/install.ps1"
    write-verbose "download puppet installer from $($url)"

    # rather then catch any errors here, explode so that user can see the real error
    # eg host down, etc
    $webClient = New-Object System.Net.WebClient; 
    $webClient.DownloadFile($url, $tempFile);
    $tempFileSize = (Get-Item $tempFile).length
    write-host "Received puppet install script ($($tempFileSize) bytes)"

    $args = "-file $($tempFile) custom_attributes:challengePassword=$($conf['shared_secret']) $($pp_ext) $($agent_certname)"
    if ($DryRun) {
        write-host "Dry run would have run powershell with args: $($args)"
    } else {
        write-verbose "Running powershell with args: $($args)"
        write-host "Transferring control to Puppet install script..."
        $p = (start-process -Passthru -FilePath "powershell" -wait -ArgumentList $args)
        $exitCode = $p.ExitCode
        if ($exitCode -ne 0) {
            fatal "Puppet install script exited with status error: $($exitCode), see previous output"
        } else {
            write-host "Puppet install script reports install OK"
        }
    }
    remove-item $tempFile
}

# Obtain a login token from VCenter, use it generate the headers we need
# This is the first REST call we make so its a good place to note that 
# `invoke-webrequest` returns a plain string in the `content` field of 
# the response. This must be converted to a powershell _object_ using
# `convertfrom-json`. The resulting object cannot be accessed as a hash, you
# must use dot notation to access its members. Later versions of PowerShell
# provide support for converting to a hash but its not in windows10/2016
function login ($conf) {
    # basic auth header
    # https://stackoverflow.com/q/27951561/3441106
    $pair = $conf["username"] + ":" + $conf["password"]

    $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $base64 = [System.Convert]::ToBase64String($bytes)
    $basicAuthValue = "Basic $base64"
    $authHeaders = @{ "Authorization" = $basicAuthValue }
    
    # get token
    write-host ($conf['server'] + "/rest/com/vmware/cis/session")
    $r = invoke-WebRequest -UseBasicParsing -uri ($conf['server'] + "/rest/com/vmware/cis/session") -method Post -Headers $authHeaders

    if ($r.StatusCode -eq 200) {
        $token = (convertfrom-json $r.content).value
        $headers = @{
            "Accept" = 'application/json';
            "vmware-api-session-id" = $token;
            "Content-Type" = 'application/json'
        }
        write-verbose "VCenter login OK"
    } else {
        fatal "Could not get VCenter authentication token - check username and password"
    }
    return $headers
}

# Lookup a VM by name, and return the tag IDs associded with it
function getVmTags($conf, $headers, $vmName) {
    $r = invoke-WebRequest -UseBasicParsing -uri ($conf["server"] + "/rest/vcenter/vm?filter.names.1=" + $vmName) -method Get -Headers $headers
    $j = convertfrom-json $r.content

    write-verbose $r.content
    if (($j.value).Count) {
        $vmId = ($j.value)[0].vm
        write-verbose "got vm ID: $($vmId), looking up associated tags"

        $payload = @{
            "object_id" = @{
                "id" = $vmId;
                "type" = "VirtualMachine"
            }
        } |convertto-json

        # get the associated tags
        $r = invoke-WebRequest -UseBasicParsing -ContentType 'application/json' -uri ($conf["server"] + "/rest/com/vmware/cis/tagging/tag-association?~action=list-attached-tags") -method Post -Headers $headers -Body $payload
        $j = convertfrom-json $r.content

        write-verbose "Associated tags: $($j|out-string)"
        $tags = $j.value
    } else {
        fatal "VCenter reports no such VM: $($vmName)"
    }
    return $tags
}

# Resolve category ID to name
function getCategoryName ($conf, $headers, $categoryId) {
    
    # find the category info for each available ID and see if its the one we want
    $r = invoke-WebRequest -UseBasicParsing -uri ($conf["server"] + "/rest/com/vmware/cis/tagging/category/id:" + $categoryId) -method "Get" -Headers $headers
    $j = $r | convertfrom-json
    $categoryName = $j.value.name
    write-verbose "category $($categoryId) --> $($categoryName)"
    return $categoryName
}

# Resolve a tag ID into its detail view which includes category ID and
# name (value)
function getTagDetail ($conf, $headers, $tagId) {

    write-verbose "resolve tag: $($tagId)"

    # Get the value of the tag we want
    $r = invoke-WebRequest -UseBasicParsing -uri ($conf["server"] + "/rest/com/vmware/cis/tagging/tag/id:" + $tagId) -method Get -Headers $headers
    $tagData = (convertfrom-json $r.content).value

    write-verbose "tag data: $($tagData)"

    # 2x fields of interest:
    # * category_id
    # * name
    write-verbose "category id $($tagId) --> $($tagData.name)"
    return $tagData
}


# create entry in /etc/hosts for puppetmaster if needed
function puppetmasterDns($conf) {
    
    $puppetMasterResolved = $false
    try {
        $puppetMasterResolved = [Net.DNS]::GetHostEntry($conf["puppet_master_host"])
    } catch {
        # couldn't resolve...
    }

    if ($puppetMasterResolved -eq $conf["puppet_master_ip"]) {
        write-host "resolved puppetmaster $($conf["puppet_master_host"]) --> $($conf["puppet_master_ip"]) (OK)"
    } else {
        write-host "Adding hosts record for puppetmaster: $($conf["puppet_master_host"])"
        Add-Content -path "C:\Windows\System32\Drivers\etc\hosts" -value "`r`n#temporary puppet master override`r`n$($conf['puppet_master_ip'])    $($conf['puppet_master_host'])`r`n"
    }
}

function main() {
    
    # enable verbose logging if required
    $OldVerbosePreference = $VerbosePreference
    if ($Verbose) {
        $VerbosePreference="continue"
    }

    disableSSLValidation
    
    # vcenter and puppet config
    $conf = loadConfig($CONFIG_SECT)

    try {
        if (! $NoHosts) {
            puppetmasterDns $conf
        }

        if ($Interactive) {
            interview $conf
        } else {
            vcenterLookup $conf
        }
    } catch {
        # catch all top level exceptions unless in debug mode
        if ($Debug) {
            # re-trow the original exception preserving the stack trace
            throw $_
        } else {
            fatal $_.Exception.Message
        }
    } finally {
        # restore default logging preference
        $VerbosePreference = $OldVerbosePreference
    }
}

# Ask the user to choose a value for `field` by entering a number
# identifying one of the allowed values
function askUser($field, $allowedValues) {
    $answer = -1
    
    $allowedCount = $allowedValues.Count
    while ($answer -lt 0) {
        write-host "Enter value for $($field): "
        for ($i = 0 ; $i -lt $allowedCount ; $i++) {
            write-host "  $($i) - $($allowedValues[$i])"
        }

        try {
            # convert to int by division
            $input = (read-host ">> ")
            $answer = $input/1
            if (-not ($input -ne "" -and $answer -ge 0 -and $answer -lt $allowedCount)) {
                write-host "Invalid selection '$($input)'. Please enter a number between 0 and $($allowedCount -1)"
                $answer = -1
            }
        } catch [System.Management.Automation.PSInvalidCastException] {
            write-host "Not a number. Please enter a number between 0 and $($allowedCount -1)"
        }
    }
    return $answer
}

# Print out the settings we have obtained from interview/vcenter
function outputSettings($tags, $finalCertname) {    
    write-host "`r`n`r`nPUPPET SETTINGS:"
    write-host "================================"
    write-host "certname --> $($finalCertname)"
    foreach ($key in $tags.keys) {
        $value = $tags."$($key)"
        write-host "$($key) --> $($value)"
    }
    write-host("================================")
}

function interview($conf) {
    write-verbose("starting interview...")
    $menu = loadConfig $MENU_SECT
    $tags = @{}


    $proceed = $false
    while (-not $proceed) {
        # confirm certname
        write-host("Enter certname for this node: ")
        $rawCertname = read-host "[$($Certname)] >> "
        $finalCertname = if ($rawCertname -eq "") {$Certname} else {$rawCertname}

        foreach ($key in $menu.keys) {
            $allowedValues = $menu[$key].split(",")
            $selected = askUser $key $allowedValues

            # if user selected "nothing" as the value, then dont use this setting
            if ($allowedValues[$selected] -ne $INTERVIEW_SKIP) {
                $tags[$key] = $allowedValues[$selected]
            }
        }
        outputSettings $tags $finalCertname
        write-host "Enter 'yes' if correct, 'no' to start again"
        if ((read-host '>> ') -eq "yes") {
            $proceed = $true
        } else {
            $tags = @{}
        }
    }
    # User entered all details, proceed to install puppet
    installPuppet $conf $DryRun $tags $finalCertname
}

# lookup in VCenter
function vcenterLookup($conf) {
    $headers = login $conf
    $vmTags = getVmTags $conf $headers $VmName

    # categories = get_categories()
    $tags = @{}

    foreach ($tagId in $vmTags) {
        $tagDetail = getTagDetail $conf $headers $tagId

        # resolve the tag ID to a name and record if we are interested
        $categoryName = getCategoryName $conf $headers $tagDetail.category_id
        if ($categoryName -Match $PP_REGEX) {
            $tags[$categoryName] = $tagDetail.name
        }
    }
    write-verbose "Found $($tags.Count) VCenter tags for $($VmName)"
    if ($tags.Count -or $Force) {
        installPuppet $conf $DryRun $tags $Certname
    } else {
        fatal "No VCenter tags matching $($PP_REGEX) for $($VmName) (re-run with `--force` to register anyway"
    }
}

main