﻿<#

.SYNOPSIS
Import-Font uses the ttx command line tool to import tables from TrueType and OpenType fonts for  further processing.

.DESCRIPTION

Import-Font takes a TrueType or OpenType (*.ttf, *.otf) font as an input and returns a custom object containing
font tables in XML format generated by the ttx tool. The object provides a number of methods to modify 
those tables. 

At this time the following Methods are available:
GetNames(): Gets a list of name entries in the name table.

SetName([int]nameID*, [int]platformID*, [int]encodingID*, [int]langID*, [string]Name*): 
    Changes a specific name entry to the specified name.

RemoveNames([int]nameID, [int]platformID, [int]encodingID, [int]langID):
    Removes one or more name entries from the name table.
    Entries will be matched using the specified IDs. Not specifying e.g. the langID will cause all language
    versions of entries specified by the supplied IDs to be removed.

GetFsFlags(): 
    Returns a bit flag enum containing the fsSelection flags (Regular, Bold, Italic, ...)
    stored in the OS/2 table.

SetsFsFlags([fsSelection]fsFlags*): 
    Sets the fsSelection flags.
    Example: SetFsFlags("Bold, Italic") or SetFsFlags(33)

AddFsFlags([fsSelection]fsFlags):
    Adds fsSelection flags and makes sure the resulting value is valid (e.g. not Regular and Bold at the same time)
    Example: AddFsFlags("Bold") sets the Bold bit and clears the Regular bit

GetWeight(): 
    Returns the font weight (Light, Regular, Medium, Bold...) as an enum.

SetWeight([usWeightClass]Weight): 
    Sets the font weight.

GetWidth(): 
    Returns the font width (Normal, Condensed, Expanded...) as an enum.

SetWidth([usWidthClass]Width*): 
    Sets the font width.

NukeNames([string]type*): 
    Removes all name table entries of a certain type. Supported Types: all, family, legal

SetNameAuto([int]NameID*, [string]Name*): 
    Removes all existing table entries associated with the supplied nameID and creates new 
    English language entries for both the Windows and Macintosh platforms with the specified name.

SetFamily([string]FamilyName, [string]SubFamilyName, [bool]winCompat): 
    Sets the font name according to supplied Family and Subfamily (style) names.
    If FamilyName isn't specified, the value will be taken from the first existing Family name entry.
    If SubFamilyName isn't specified, a Style name will be build using the Weight/Width/fsSelection
    information in the OS/2 table.

.PARAMETER InFile
Font to import.
Alias: -i

.PARAMETER Tables
Comma-delimited list of tables to import.
    Available tables: all, cmap, head, hhea, hmtx, maxp, name, OS/2, post, cvt, fpgm, glyf, loca, prep, 
                      CFF, VORG, BASE, GDEF, GPOS, GSUB, JSTF, DSIG, gasp, hdmx, kern, LTSH, PCLT, VDMX,
                      vhea, vmtx
Defaults to: name, OS/2, head
Alias: -t

.EXAMPLE
$font = Import-Font X:\font.ttf

.LINK
https://github.com/line0/FontToys

#>
#requires -version 3

function Import-Font
{
[CmdletBinding()]
param
(
[Parameter(Position=0, Mandatory=$true, HelpMessage='Path to TrueType/OpenType font to import.')]
[alias("i")]
[string]$InFile,
[Parameter(Mandatory=$false, HelpMessage='Comma-delimited list of tables to import.')]
[alias("t")]
[string[]]$Tables = @("name", "OS/2", "head")
)
    
    Check-CmdInPath mkvinfo.exe -Name mkvtoolnix
    try { $font = Get-Files $InFile -match '.[t|o]tf$' -matchDesc "TrueType/OpenType font"}
    catch
    {
        if($_.Exception.WasThrownFromThrowStatement -eq $true)
        {
            Write-Host $_.Exception.Message -ForegroundColor Red
            break
        }
        else {throw $_.Exception}
    }
    $ttxFile = Join-Path $env:temp ($font.BaseName+".Import.ttx")
    $ttxlog = &ttx $($Tables | %{"-t$_"}) -o $ttxFile $font
    $xml = [xml](Get-Content $ttxFile)
    Remove-Item $ttxFile

    .(Join-Path (Split-Path -parent $PSCommandPath) "Types.ps1")

    $fontInfo=[PSCustomObject]@{
        XML = $xml
        Path = $font

    } | Add-Member -Name GetNames -PassThru -MemberType ScriptMethod -Value `
        { 
            param([int]$nameId, [int]$platformId, [int]$encId, [int]$langId)
            @{
                nameID = $nameId
                platformId = $platformId
                platEncId = $encId
                langId = if ($langId) {"0x{0:x}" -f $langId}
            }.GetEnumerator() | ?{$_.Value} | %{$names=$this.XML.ttFont.name.namerecord}`
                                {$x=$_; $names = ($names | ?{$_.($x.Key) -eq $x.Value})}
       
            return $names | Select-Object -Property `
                            @{Name="NameID"; Expression={[int]$_.nameID}},
                            @{Name="PlatformID"; Expression={[int]$_.platformID}},
                            @{Name="EncID"; Expression={[int]$_.platEncID}}, 
                            @{Name="LangID"; Expression={[int]$_.langId}}, @{Name="Name"; Expression={$_."#text".Trim()}} `
                          | Sort-Object NameID, PlatformID, LangID
        } `
      | Add-Member -Name SetName -PassThru -MemberType ScriptMethod -Value `
        { 
            param([Parameter(Mandatory=$true)][int]$nameId, [Parameter(Mandatory=$true)][int]$platformId, 
                  [Parameter(Mandatory=$true)][int]$encId, [Parameter(Mandatory=$true)][int]$langId, [Parameter(Mandatory=$true)][string]$name)
            $nameRecord = $this.XML.ttFont.name.namerecord`
                        | ?{$_.nameID -eq $nameId -and $_.platformId -eq $platformId -and 
                            $_.langId -eq ("0x{0:x}" -f $langId) -and $_.platEncId -eq $encId}
            if ($nameRecord) {
                $nameRecord."#text" = "`n$name`n"
            } else {
                $newRecord = $this.XML.CreateElement('namerecord')
                $newRecord.SetAttribute('nameID', $nameId)
                $newRecord.SetAttribute('platformID', $platformId)
                $newRecord.SetAttribute('platEncID', $encId)
                $newRecord.SetAttribute('langID', "0x{0:x}" -f $langId)
                $newRecord.InnerText = $name
                $nameRecord = $this.XML.SelectSingleNode('ttFont/name').AppendChild($newRecord)
            }
        } `
      | Add-Member -Name RemoveNames -PassThru -MemberType ScriptMethod -Value `
        { 
            param([int]$nameId, [int]$platformId, [int]$encId, [int]$langId)
            # can't reuse $this.GetNames() because we no longer have access to the ParentNode
            @{
                nameID = $nameId
                platformId = $platformId
                platEncId = $encId
                langId = if ($langId) {"0x{0:x}" -f $langId}
            }.GetEnumerator() | ?{$_.Value} | %{$names=$this.XML.ttFont.name.namerecord}`
                                {$x=$_; $names = ($names | ?{$_.($x.Key) -eq $x.Value})}
            $names = $names | %{$_.ParentNode.RemoveChild($_)}

        } `
      | Add-Member -Name GetFsFlags -PassThru -MemberType ScriptMethod -Value `
        { 
            $fsSelInt = [convert]::ToInt32(($this.XML.ttfont.OS_2.fsSelection.value -replace " ",""),2)
            return [fsSelection]$fsSelInt
        
        } `
      | Add-Member -Name SetFsFlags -PassThru -MemberType ScriptMethod -Value `
        { 
            param([fsSelection]$fsSel)
            $fsSelBin = [convert]::ToString([int]$fsSel,2)
            $this.XML.ttfont.OS_2.fsSelection.value = ("0"*(16-$fsSelBin.Length) + $fsSelBin).Insert(8," ")
        } `
      | Add-Member -Name AddFsFlags -PassThru -MemberType ScriptMethod -Value `
        { 
            param([int]$fsSel)
            
            $fsSelOld = [int]$this.GetFsFlags()
           
            if ($fsSel % 128 -ne 64 -and $fsSel % 128 -ne 0 -and [fsSelection]$fsSelOld -match "Regular")
            {
                $fsSel = $fsSelOld -bor $fsSel -bxor 64
            }
            elseif ([fsSelection]$fsSel -match "Regular" -and $fsSelOld % 128 -ne 64 )
            {
                $fsSel = ($fsSel - $fsSel%128) -bor ($fsSelOld - $fsSelOld%128) + 64
            }
            else { $fsSel = $fsSelOld -bor $fsSel }
            $this.SetFsFlags($fsSel)
        } `
      | Add-Member -Name GetWeight -PassThru -MemberType ScriptMethod -Value `
        { 
            return [usWeightClass][int]$this.XML.ttfont.OS_2.usWeightClass.value        
        } `
      | Add-Member -Name SetWeight -PassThru -MemberType ScriptMethod -Value `
        { 
            param([usWeightClass]$weight)
            $this.XML.ttfont.OS_2.usWeightClass.value = [string][int]$weight     
        } `
      | Add-Member -Name GetWidth -PassThru -MemberType ScriptMethod -Value `
        { 
            return [usWidthClass][int]$this.XML.ttfont.OS_2.usWidthClass.value        
        } `
      | Add-Member -Name SetWidth -PassThru -MemberType ScriptMethod -Value `
        { 
            param([usWidthClass]$width)
            $this.XML.ttfont.OS_2.usWidthClass.value = [string][int]$width     
        } `
      | Add-Member -Name NukeNames -PassThru -MemberType ScriptMethod -Value `
        { 
            param([string]$type="all")
            $names = switch($type)
            {
                "family" {@(1,2,3,4,6,16,17,18)}
                "legal" {@(0,7,13,14)}
                "all" {0..30}
            }
            $names | %{ $this.RemoveNames($_)}
        } `
      | Add-Member -Name SetNameAuto -PassThru -MemberType ScriptMethod -Value `
        { 
            param([Parameter(Mandatory=$true)][int]$nameId, [Parameter(Mandatory=$true)][string]$name)
        
            $this.RemoveNames($nameId)
            $this.SetName($nameId,1,0,0,$name)
            $this.SetName($nameId,3,1,1033,$name)
        } `
      | Add-Member -Name SetVersion -PassThru -MemberType ScriptMethod -Value `
        { 
            param([Parameter(Mandatory=$false)][int]$version, [Parameter(Mandatory=$false)][int]$revision=0)
            
            if(!$version)
            {
                $regex = "^(\d+)(?:\.(\d+))?"
                $matches = select-string -InputObject $this.XML.ttFont.head.fontRevision.value -pattern $regex  | Select -ExpandProperty Matches
                [int]$version = $matches.Groups[1].Value
                [int]$revision = $matches.Groups[2].Value
            } else {
                $this.XML.ttFont.head.fontRevision.value = "$version.$revision"
            }

            $verString = "Version {0}.{1}" -f $version,$revision.ToString("000")
            $this.SetNameAuto(5,$verString)
        } `
      | Add-Member -Name SetFamily -PassThru -MemberType ScriptMethod -Value `
        { 
            param([string]$familyName, [string]$subFamilyName, [bool]$winCompat=$true)
            if (!$familyName) { 
                $familyName = ($this.GetNames(1) | ?{$_.Name.Trim()})[0].Name
            }
            if (!$subFamilyName) {
                $weight = [string]$this.GetWeight()
                $width = [string]$this.GetWidth()
                $fsFlags =  ([string][fsSelection]([int]$this.GetFsFlags() % 128)) -Split ", " | ?{!$weight -or $_ -ne "Bold"}
                if ($fsFlags) {[array]::reverse($fsFlags)}
                $subFamilyName = (@($width, $weight) + $fsFlags | ?{$_ -and $_ -notin @("Regular","Normal")}) -join " "
                if (!$subFamilyName) { $subFamilyName = "Regular" }
            }

            $this.NukeNames("family")

            $styleParts = $subFamilyName -split " "
            $subFamilyEx = ($styleParts | ?{$_ -notin @("Regular","Normal")}) -join " "
            $this.SetNameAuto(4, @($familyName, $subFamilyEx) -join " ")
            
            $psName = (@($familyName, $subFamilyName) -join "-") -replace " ",""
            $this.SetNameAuto(6, $psName.Substring(0,[Math]::Min($psName.length,31)))

            if ($winCompat)
            {
                $this.SetName(16,3,1,1033, $familyName)
                $this.SetName(17,3,1,1033, $subFamilyName)
                
                $splitOff = @("Bold","Italic","Regular")
                $familyName = @($familyName) + ($styleParts | ?{$_ -notin $splitOff}) -join " "
                $subFamilyName = ($styleParts | ?{$_ -in $splitOff}) -join " "
                if (!$subFamilyName) { $subFamilyName = "Regular" }
            }

            $this.SetNameAuto(1, $familyName)
            $this.SetNameAuto(2, $subFamilyName)

            $manuCandidates=@(
                $this.GetNames(8,1,0,0).Name,
                $this.GetNames(8,3,1,1033).Name,
                ,@($this.GetNames(8))[0].Name,
                $this.GetNames(9,1,0,0).Name,
                $this.GetNames(9,3,1,1033).Name,
                ,@($this.GetNames(9))[0].Name,
                "Unknown"  
            )
            foreach($manuCandidate in $manuCandidates)
            {
                if ($manuCandidate -and $manuCandidate.Trim()) {
                    $manufacturer = $manuCandidate
                    break;
                }
            }

            $this.SetVersion()
            $this.SetNameAuto(3,("{0}: {1} (FontToys)" -f $manufacturer,$this.GetNames(4,1,0,0).Name))
        }

    return $fontInfo
}


Export-ModuleMember Import-Font