$Global:JENKINS_URL = "https://updates.jenkins-ci.org/"
$Global:JENKINS_WAR_URL = $Global:JENKINS_URL + "/download/war/"
$Global:JENKINS_PLUGINS_URL = $Global:JENKINS_URL + "/download/plugins/"
$Global:FOLDER_LOCATION = $env:USERPROFILE + "\Desktop\jenkins\"
$Global:FOLDER_LOCATION_FOR_PLUGINS = $Global:FOLDER_LOCATION + "Plugins\"
$Global:JENKINS_DEFAULT_PLUGINS_JSON = $MyInvocation.ScriptName.DirectoryName + "default-plugins.json"
$Global:JENKINS_PLUGINS_OBJECT = [System.Object]
$Global:JENKINS_HOME = $env:USERPROFILE + "\.jenkins\"
$Global:JENKINS_ADMIN_SECRET = $Global:JENKINS_HOME + "\secrets\initialAdminPassword"

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
            $request.set_Timeout(30000) # 5 second timeout
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
        [Parameter(Mandatory, Position = 0)]
        [string]$PluginName
    )
    (Invoke-WebRequest -UseBasicParsing $Global:JENKINS_PLUGINS_URL$PluginName).Content | % { [regex]::matches($_, "(?:<a href=')(.*)(?:' .*' '>)").Groups[3].Value }
}

function Get-LatestWarLink {
    (Invoke-WebRequest -UseBasicParsing $Global:JENKINS_WAR_URL).Content | % { [regex]::matches($_, "(?:<a href=')(.*)(?:' .*' '>)").Groups[1].Value }
}

function Get-LatestWarHash {
    (((Invoke-WebRequest -UseBasicParsing $Global:JENKINS_WAR_URL).Content | % { [regex]::matches($_, '(?:<td>)(.*)(?:<td>)(.*)(SHA-256: .*)(?:</td>)').Groups[3].Value }).replace('SHA-256: ', '')).toUpper()
}

function ProgressFor-WarFile {
    Download-JenkinsWar
}

function ProgressFor-Plugins {
    Read-JenkinsPluginsFromJson
    $isPluginFolderExist = Check-PluginsFolderExists
    if (!$isPluginFolderExist) {
        New-Item -Type directory -Path $Global:FOLDER_LOCATION_FOR_PLUGINS -Force | Out-Null
    }
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
        $Global:JENKINS_PLUGINS_OBJECT | ForEach-Object { $_.plugins.name } | ForEach-Object { Get-LatestPluginLink -PluginName $_ } | ForEach-Object { Get-FileFromURL -URL $Global:JENKINS_URL$_ -Filename ($Global:FOLDER_LOCATION_FOR_PLUGINS + $_.Substring($_.LastIndexOf('/')).replace('/', '')) }
    }
}

function Setup-Java() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$filePath
    )
    if ((Test-Path -Path "$filePathjre8.exe") -eq "False") {
        #Java 8 indirilir ve kurulur.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $URL = (Invoke-WebRequest -UseBasicParsing https://www.java.com/en/download/manual.jsp).Content | % { [regex]::matches($_, '(?:<a title="Download Java software for Windows [(]64-bit[)]" href=")(.*)(?:">)').Groups[1].Value }
        Get-FileFromURL -URL $URL -Filename "$filePath\jre8.exe"
    }
    #Invoke-WebRequest -UseBasicParsing -OutFile "$filePath\jre8.exe" $URL
    Start-Process "$filePath\jre8.exe" '/s REBOOT=0 SPONSORS=0 AUTO_UPDATE=0' -Wait
    $result = $?
    Remove-Item -Path "$filePath\jre8.exe" -Force
    $result
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

function Download-JenkinsCli {
    $JenkinsCliJarUrl = "http://localhost:8080/jnlpJars/jenkins-cli.jar"
    $JenkinsCliDownloadPath = $Global:FOLDER_LOCATION + "jenkins-cli.jar"
    Get-FileFromURL -URL $JenkinsCliJarUrl -Filename $JenkinsCliDownloadPath
}

function Copy-Configurations {
    Copy-Item 
}

function Start-Jenkins {
    
    $title = 'Jenkins islemi'
    $question = 'Jenkins simdi baslatilsin mi?'
    $choices = '&Evet', '&Hayir'

    $decision = $Host.UI.PromptForChoice($title, $question, $choices, 1)
    if ($decision -eq 0) {
        $jenkinsApp = Start-Process -FilePath javaw -ArgumentList '-jar', 'jenkins.war' -RedirectStandardOutput '.\console.out' -RedirectStandardError '.\console.err' -PassThru
        $jenkinsApp
    }
    else {
        Write-Host 'Islem iptal edildi.'
    }        
}

function Wait-JenkinsStart {
    while ($true) { Start-Sleep -Second 1; Get-Content ($env:USERPROFILE + "\Desktop\jenkins\console.err") -Tail 100 | Select-String "Jenkins is fully up and running" | % { write-host Found $_; break } }
}

$isFolderExist = Check-JenkinsSetupFolderExists
if (!$isFolderExist) {
    New-Item -ItemType Directory -Path $Global:FOLDER_LOCATION -Force | Out-Null
}
$Global:IS_WAR_EXIST = Check-WarExists

if (!$Global:IS_WAR_EXIST) {
    ProgressFor-WarFile
}
else {
    $latestHash = Get-LatestWarHash
    $isConsistent = Check-FileHashes -Hash $latestHash -Filepath ($Global:FOLDER_LOCATION + "jenkins.war")
    if (!$isConsistent) {
        Write-Host "War File is not the latest version. Latest version is downloading." -ForegroundColor Cyan 
        ProgressFor-WarFile
    }
}

ProgressFor-Plugins
Set-Location -Path $Global:FOLDER_LOCATION

if (((Get-Command java | Select-Object -ExpandProperty Version).tostring() -notmatch "^8.0")) {
    $title = 'Java Yukle'
    $question = "PC'nizde java yok veya PC'nizdeki java eski surum. Devam etmek icin java 8 versiyonunu yuklemeniz gerekmektedir. Java 8 Yuklensin mi?"
    $choices = '&Evet', '&Hayir'

    $decision = $Host.UI.PromptForChoice($title, $question, $choices, 1)
    if ($decision -eq 0) {
        $setupJava = Setup-Java $Global:FOLDER_LOCATION
        Start-Jenkins
    }
    else {
        Write-Host 'Islem iptal edildi.'
    }
}
else {
    $GLOBAL:jenkinsApp = Start-Jenkins

    if ($null -ne $GLOBAL:jenkinsApp.Id) {
        Wait-JenkinsStart
        Download-JenkinsCli
    }
    else {
        Write-Host 'Jenkins baslatilamadi.' -ForegroundColor Red
    }
}
