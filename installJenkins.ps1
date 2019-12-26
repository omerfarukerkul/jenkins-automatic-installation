$Global:JENKINS_URL = "https://updates.jenkins-ci.org/"
$Global:JENKINS_WAR_URL = $Global:JENKINS_URL + "/download/war/"
$Global:JENKINS_PLUGINS_URL = $Global:JENKINS_URL + "/download/plugins/"
$Global:FOLDER_LOCATION = $env:USERPROFILE + "\Desktop\jenkins\"
$Global:FOLDER_LOCATION_FOR_PLUGINS = $Global:FOLDER_LOCATION + "Plugins\"
$Global:JENKINS_DEFAULT_PLUGINS_JSON = $MyInvocation.ScriptName.DirectoryName + "default-plugins.json"
$Global:JENKINS_PLUGINS_OBJECT = [System.Object]

$Global:PLUGIN_ITEM_COUNT = 0
$Global:IS_WAR_EXIST = $false
$Global:EXISTING_PLUGIN_NAMES = [System.Object]

function Get-FileFromURL {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [System.Uri]$URL,
        [Parameter(Mandatory, Position = 1)]
        [string]$Filename
    )

    process {
        try {
            $request = [System.Net.HttpWebRequest]::Create($URL)
            $request.set_Timeout(5000) # 5 second timeout
            $response = $request.GetResponse()
            $total_bytes = $response.ContentLength
            $response_stream = $response.GetResponseStream()

            try {
                # 256KB works better on my machine for 1GB and 10GB files
                # See https://www.microsoft.com/en-us/research/wp-content/uploads/2004/12/tr-2004-136.pdf
                # Cf. https://stackoverflow.com/a/3034155/10504393
                $buffer = New-Object -TypeName byte[] -ArgumentList 256KB
                $target_stream = [System.IO.File]::Create($Filename)

                $timer = New-Object -TypeName timers.timer
                $timer.Interval = 500 # Update progress every second
                $timer_event = Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action {
                    $Global:update_progress = $true
                }
                $timer.Start()

                do {
                    $count = $response_stream.Read($buffer, 0, $buffer.length)
                    $target_stream.Write($buffer, 0, $count)
                    $downloaded_bytes = $downloaded_bytes + $count

                    if ($Global:update_progress) {
                        $percent = $downloaded_bytes / $total_bytes
                        $status = @{
                            completed  = "{0,6:p2} Completed" -f $percent
                            downloaded = "{0:n0} MB of {1:n0} MB" -f ($downloaded_bytes / 1MB), ($total_bytes / 1MB)
                            speed      = "{0,7:n0} KB/s" -f (($downloaded_bytes - $prev_downloaded_bytes) / 1KB)
                            eta        = "eta {0:hh\:mm\:ss}" -f (New-TimeSpan -Seconds (($total_bytes - $downloaded_bytes) / ($downloaded_bytes - $prev_downloaded_bytes)))
                        }
                        $progress_args = @{
                            Activity        = "Downloading $URL"
                            Status          = "$($status.completed) ($($status.downloaded)) $($status.speed) $($status.eta)"
                            PercentComplete = $percent * 100
                        }
                        Write-Progress @progress_args

                        $prev_downloaded_bytes = $downloaded_bytes
                        $Global:update_progress = $false
                    }
                } while ($count -gt 0)
            }
            finally {
                if ($timer) { $timer.Stop() }
                if ($timer_event) { Unregister-Event -SubscriptionId $timer_event.Id }
                if ($target_stream) { $target_stream.Dispose() }
                # If file exists and $count is not zero or $null, than script was interrupted by user
                if ((Test-Path $Filename) -and $count) { Remove-Item -Path $Filename }
            }
        }
        finally {
            if ($response) { $response.Dispose() }
            if ($response_stream) { $response_stream.Dispose() }
        }
    }
}

function Read-JenkinsPluginsFromJson {
    $Global:JENKINS_PLUGINS_OBJECT = Get-Content -Raw -Path $Global:JENKINS_DEFAULT_PLUGINS_JSON | ConvertFrom-Json
}

function Download-JenkinsWar {
    $LatestWarLink = Get-LatestWarLink
    $LatestWarLink = $Global:JENKINS_URL + $LatestWarLink
    Get-FileFromURL -URL $LatestWarLink -Filename ($Global:FOLDER_LOCATION + "jenkins.war")
}

function Check-PluginsFolderExists {
    Test-Path -Path ($Global:FOLDER_LOCATION_FOR_PLUGINS)
}
function Check-PluginsFolder {
    (dir $Global:FOLDER_LOCATION_FOR_PLUGINS | measure).Count
}

function Check-WarExists {
    Test-Path -Path ($Global:FOLDER_LOCATION + "jenkins.war")
}
function Check-JenkinsSetupFolderExists {
    Test-Path -Path ($Global:FOLDER_LOCATION)
}
function Get-LatestPluginLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 1)]
        [string]$PluginName
    )
    (Invoke-WebRequest -UseBasicParsing $Global:JENKINS_PLUGINS_URL$PluginName).Content | % { [regex]::matches($_, "(?:<a href=')(.*)(?:' .*' '>)").Groups[3].Value }
}

function Get-LatestWarLink {
    (Invoke-WebRequest -UseBasicParsing $Global:JENKINS_WAR_URL).Content | % { [regex]::matches($_, "(?:<a href=')(.*)(?:' .*' '>)").Groups[3].Value }
}

function Get-LatestWarHash {
    (((Invoke-WebRequest -UseBasicParsing $Global:JENKINS_WAR_URL).Content | % { [regex]::matches($_, '(?:<td>)(.*)(?:<td>)(.*)(SHA-256: .*)(?:</td>)').Groups[3].Value }).replace('SHA-256: ', '')).toUpper()
}

function ProgressFor-WarFile {
    Read-JenkinsPluginsFromJson
    Download-JenkinsWar
}

function ProgressFor-Plugins {
    $isPluginFolderExist = Check-PluginsFolderExists
    if (!$isPluginFolderExist) {
        New-Item -Type directory -Path $Global:FOLDER_LOCATION_FOR_PLUGINS -Force | Out-Null
    }
    Read-JenkinsPluginsFromJson
    $pluginCount = Check-PluginsFolder
    if ($pluginCount -gt 0) {
        $Global:EXISTING_PLUGIN_NAMES = Get-ChildItem $Global:FOLDER_LOCATION_FOR_PLUGINS
        $filenames = $Global:EXISTING_PLUGIN_NAMES.Name.Replace(".hpi", "")
        $Global:SUBTRACTED_PLUGINS = $Global:JENKINS_PLUGINS_OBJECT.plugins | ? { $_.name -notin $filenames }
        if ($null -ne $Global:SUBTRACTED_PLUGINS) {
            if ($Global:SUBTRACTED_PLUGINS.name.Count -gt 0) {
                $Global:SUBTRACTED_PLUGINS.name | ForEach-Object { Get-LatestPluginLink -PluginName $_ } | ForEach-Object { Get-FileFromURL -URL $Global:JENKINS_URL$_ -Filename ($Global:FOLDER_LOCATION_FOR_PLUGINS + $_.Substring($_.LastIndexOf('/')).replace('/', '')) }            
            }
        }
    }
    if ($pluginCount -eq 0) {
        $Global:JENKINS_PLUGINS_OBJECT | ForEach-Object { Where-Object { $_.plugins.name } } | ForEach-Object { Get-LatestPluginLink -PluginName $_ } | ForEach-Object { Get-FileFromURL -URL $Global:JENKINS_URL$_ -Filename ($Global:FOLDER_LOCATION_FOR_PLUGINS + $_.Substring($_.LastIndexOf('/')).replace('/', '')) }
    }
}

function Check-FileHashes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Hash,
        [Parameter(Mandatory, Position = 1)]
        [string]$Filepath
    )

    $file = $Filepath

    $hashFromFile = Get-FileHash -Path $file -Algorithm SHA256

    # Check both hashes are the same
    if ($hashFromFile.Hash -eq $Hash) {
        $true
    }
    else {
        $false
    }
}

$isFolderExist = Check-JenkinsSetupFolderExists

if (!$isFolderExist) {
    New-Item -ItemType Directory -Path $Global:FOLDER_LOCATION -Force | Out-Null
}
$Global:IS_WAR_EXIST = Check-WarExists

if (!$Global:IS_WAR_EXIST) {
    ProgressFor-WarFile
}
$latestHash = Get-LatestWarHash
$isConsistent = Check-FileHashes -Hash $latestHash -Filepath ($Global:FOLDER_LOCATION + "jenkins.war")
if (!$isConsistent) {
    Write-Host "War File is not the latest version. Latest version is downloading." -ForegroundColor Cyan 
    ProgressFor-WarFile
}
ProgressFor-Plugins
Set-Location -Path $Global:FOLDER_LOCATION
$title = 'Jenkins islemi'
$question = 'Jenkins simdi baslatilsin mi?'
$choices = '&Evet', '&Hayir'

$decision = $Host.UI.PromptForChoice($title, $question, $choices, 1)
if ($decision -eq 0) {
    $jenkinsApp = Start-Process -FilePath javaw -ArgumentList '-jar', 'jenkins.war' -RedirectStandardOutput '.\console.out' -RedirectStandardError '.\console.err'
}
else {
    Write-Host 'İslem iptal edildi.'
}
