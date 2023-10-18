# ----------------------------------------------------------------------------------
#
# Copyright Microsoft Corporation
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ----------------------------------------------------------------------------------

# To get upcoming breaking change info, you need to build az first
# ```powershell
# dotnet msbuild build.proj /t:build /p:configuration=Debug
# Import-Module ./tools/BreakingChanges/GetUpcomingBreakingChangeSource.ps1
# Export-BreakingChangeFileInfo -ArtifactsPath ./artifacts/Debug/
# ```


Function Test-TypeIsGenericBreakingChangeAttribute
{
    [CmdletBinding()]
    Param(
        [Parameter()]
        [System.Reflection.TypeInfo[]]
        $type
    )
    ForEach ($loopType in $type)
    {
        While ($loopType.Name -ne "Object")
        {
            If ($loopType.Name -eq "GenericBreakingChangeAttribute")
            {
                Return $True
            }
            $loopType = $loopType.BaseType
        }
    }
    Return $False
}

Function Test-TypeIsGenericBreakingChangeWithVersionAttribute
{
    [CmdletBinding()]
    Param(
        [Parameter()]
        [System.Reflection.TypeInfo[]]
        $type
    )
    ForEach ($loopType in $type)
    {
        While ($loopType.Name -ne "Object")
        {
            If ($loopType.Name -eq "GenericBreakingChangeWithVersionAttribute")
            {
                Return $True
            }
            $loopType = $loopType.BaseType
        }
    }
    Return $False
}

# Get the breaking change info of the cmdlet.
Function Find-CmdletBreakingChange
{
    [CmdletBinding()]
    Param (
        [Parameter()]
        [string]
        $ModuleName,
        [Parameter()]
        [System.Management.Automation.CommandInfo]
        $CmdletInfo,
        [Parameter()]
        [String]
        $BreakingChangeInfo
    )
    #Region get breaking change info of cmdlet
    $customAttributes = $CmdletInfo.ImplementingType.GetTypeInfo().GetCustomAttributes([System.object], $true)
    $CmdletName = $CmdletInfo.Name
    $CmdletClassName = $CmdletInfo.ImplementingType.Name
    $ModuleName = $ModuleName.Split(".")[1]
    $ModuleFolder = Join-Path $PSScriptRoot "..\..\src\$ModuleName"
    ForEach ($customAttribute In $customAttributes)
    {
        If (Test-TypeIsGenericBreakingChangeWithVersionAttribute $customAttribute.TypeId)
        {
            $FilePath = Get-ChildItem -Path $ModuleFolder -Recurse -File | Where-Object { Get-Content $_.FullName | Select-String -Pattern "class $CmdletClassName :" } | ForEach-Object {$_.FullName}
            if ($FilePath -ne "" -and $Null -ne $FilePath)
            {
                $FilePath = $FilePath.replace("/", "\").split("src\")[1]
            }

            $BreakingChangeInfo += "$ModuleName,$CmdletName,$FilePath`n"
        }
    }
    #EndRegion

    #Region get breaking change info of parameters
    ForEach ($ParameterInfo In $CmdletInfo.Parameters.values)
    {
        ForEach ($attribute In $ParameterInfo.Attributes)
        {
            If (Test-TypeIsGenericBreakingChangeWithVersionAttribute $attribute.TypeId)
            {
                $FilePath = Get-ChildItem -Path $ModuleFolder -Recurse -File | Where-Object { Get-Content $_.FullName | Select-String -Pattern "class $CmdletClassName :" } | ForEach-Object {$_.FullName}
                if ($FilePath -ne "" -and $Null -ne $FilePath)
                {
                    $FilePath = $FilePath.replace("/", "\").split("src\")[1]
                }
                $BreakingChangeInfo += "$ModuleName,$CmdletName,$FilePath,$($ParameterInfo.Name)`n"
            }
        }
    }
    #EndRegion
    return $BreakingChangeInfo
}

Function Get-BreakingChangeInfoOfModule
{
    [CmdletBinding()]
    Param (
        [Parameter()]
        [String]
        $ArtifactsPath,
        [Parameter()]
        [String]
        $ModuleName,
        [Parameter()]
        [String]
        $BreakingChangeInfo
    )
    $ModuleRoot = [System.IO.Path]::Combine($ArtifactsPath, $ModuleName)

    #Region Generated modules
    $Dlls = Get-ChildItem -Path $ModuleRoot -Filter *.private.dll -Recurse
    ForEach ($Dll In $Dlls)
    {
        $CustomRoot = [System.IO.Path]::Combine($Dll, '..', '..', 'custom')
        $Psm1Path = Get-ChildItem -Path $CustomRoot -Filter *.psm1
        $BreakingChangeInfo = Get-BreakingChangeOfGeneratedModule -DllPath $Dll -Psm1Path $Psm1Path -ModuleName $ModuleName -BreakingChangeInfo $BreakingChangeInfo
    }
    #EndRegion

    #Region SDK based modules
    If (-Not (Test-Path -Path ([System.IO.Path]::Combine($ModuleRoot, "generated"))))
    {
        $psd1Path = [System.IO.Path]::Combine($ModuleRoot, "$ModuleName.psd1")
        Import-Module $psd1Path
        $ModuleInfo = Get-Module $ModuleName
        ForEach ($cmdletInfo In $ModuleInfo.ExportedCmdlets.Values)
        {
            $BreakingChangeInfo = Find-CmdletBreakingChange -ModuleName $ModuleName -CmdletInfo $cmdletInfo -BreakingChangeInfo $BreakingChangeInfo
        }
    }
    #EndRegion
    return $BreakingChangeInfo
}

Function Get-BreakingChangeOfGeneratedModule
{
    [CmdletBinding()]
    Param (
        [Parameter()]
        [String]
        $DllPath,
        [Parameter()]
        [String]
        $Psm1Path,
        [Parameter()]
        [String]
        $ModuleName,
        [Parameter()]
        [String]
        $BreakingChangeInfo
    )
    $ModuleName = $ModuleName.Split(".")[1]

    #Region Dll
    $Dll = [Reflection.Assembly]::LoadFrom($DllPath)
    $Cmdlets = $Dll.ExportedTypes | Where-Object { $_.CustomAttributes.Attributetype.name -contains "GeneratedAttribute" -and ($_.CustomAttributes.Attributetype.name -notcontains "InternalExportAttribute") }

    $BreakingChangeCmdlets = $Cmdlets | Where-Object { Test-TypeIsGenericBreakingChangeAttribute $_.CustomAttributes.Attributetype }
    ForEach ($BreakingChangeCmdlet in $BreakingChangeCmdlets)
    {
        $CmdletAttribute = $BreakingChangeCmdlet.CustomAttributes | Where-Object { $_.AttributeType.Name -eq 'CmdletAttribute' }
        $Verb = $CmdletAttribute.ConstructorArguments[0].Value
        $Noun = $CmdletAttribute.ConstructorArguments[1].Value.Split('_')[0]
        $CmdletName = "$Verb-$Noun"

        $BreakingChangeAttributes = $BreakingChangeCmdlet.CustomAttributes | Where-Object { Test-TypeIsGenericBreakingChangeAttribute $_.Attributetype }
        $AttributeTypeList = $BreakingChangeAttributes | Select-Object -ExpandProperty AttributeType -Unique
        ForEach ($AttributeType In $AttributeTypeList)
        {
            $AttributeList = $BreakingChangeCmdlet.GetCustomAttributes($AttributeType, $true)
            ForEach ($Attribute In $AttributeList)
            {
                Write-Host "$ModuleName,$CmdletName,READMD.md`n"
                $BreakingChangeInfo += "$ModuleName,$CmdletName,READMD.md`n"
            }
        }
    }

    ForEach ($Cmdlet in $Cmdlets)
    {
        $CmdletAttribute = $Cmdlet.CustomAttributes | Where-Object { $_.AttributeType.Name -eq 'CmdletAttribute' }
        $Verb = $CmdletAttribute.ConstructorArguments[0].Value
        $Noun = $CmdletAttribute.ConstructorArguments[1].Value.Split('_')[0]
        $CmdletName = "$Verb-$Noun"

        $Parameters = $Cmdlet.DeclaredMembers | Where-Object { Test-TypeIsGenericBreakingChangeAttribute $_.CustomAttributes.Attributetype }
        ForEach ($Parameter In $Parameters)
        {
            $ParameterName = $Parameter.Name
            $ParameterAttribute = $Parameter.CustomAttributes | Where-Object { Test-TypeIsGenericBreakingChangeAttribute $_.AttributeType }
            $AttributeTypeList = $ParameterAttribute | Select-Object -ExpandProperty AttributeType -Unique
            ForEach ($AttributeType In $AttributeTypeList)
            {
                $AttributeList = $Parameter.GetCustomAttributes($AttributeType, $true)
                ForEach ($Attribute In $AttributeList)
                {
                    Write-Host "$ModuleName,$CmdletName,READMD.md,$ParameterName`n"
                    $BreakingChangeInfo += "$ModuleName,$CmdletName,READMD.md,$ParameterName`n"
                }
            }
        
        }
    }
    #EndRegion

    #Region psm1
    Import-Module $Psm1Path -Force
    $ModuleName = (Get-Item $Psm1Path).BaseName
    $ModuleInfo = Get-Module $ModuleName
    $BreakingChangeCmdlets = $ModuleInfo.ExportedCommands.Values | Where-Object { Test-TypeIsGenericBreakingChangeAttribute $_.ScriptBlock.Attributes.TypeId }
    ForEach ($BreakingChangeCmdlet In $BreakingChangeCmdlets)
    {
        $CmdletName = $BreakingChangeCmdlet.Name
        $FilePath = "custom\$CmdletName.ps1"
        $BreakingChangeAttributes = $BreakingChangeCmdlet.ScriptBlock.Attributes | Where-Object { Test-TypeIsGenericBreakingChangeAttribute $_.TypeId }
        ForEach ($BreakingChangeAttribute In $BreakingChangeAttributes)
        {
            Write-Host "$ModuleName,$CmdletName,$FilePath`n"
            $BreakingChangeInfo += "$ModuleName,$CmdletName,$FilePath`n"
        }
    }

    $Cmdlets = $ModuleInfo.ExportedCommands.Values
    ForEach ($Cmdlet In $Cmdlets)
    {
        $CmdletName = $Cmdlet.Name
        $FilePath = "custom\$CmdletName.ps1"
        $Parameters = $Cmdlet.Parameters.Values | Where-Object { Test-TypeIsGenericBreakingChangeAttribute $_.Attributes.TypeId }
        ForEach ($Parameter In $Parameters)
        {
            Write-Host "$ModuleName,$CmdletName,$FilePath,$ParameterName`n"
            $BreakingChangeInfo += "$ModuleName,$CmdletName,$FilePath,$ParameterName`n"
        }
    }
    #EndRegion
    return $BreakingChangeInfo
}

Function Export-BreakingChangeFileInfo
{
    [CmdletBinding()]
    Param (
        [Parameter()]
        [String]
        $ArtifactsPath,
        [Parameter()]
        [String]
        $ExportCsvPath = "BreakingChangeInfo.csv"
    )
    $BreakingChangeInfo = "ModuleName,CmdletName,FilePath,ParameterName`n"
    $AllModuleList = Get-ChildItem -Path $ArtifactsPath -Filter Az.* | ForEach-Object { $_.Name }
    ForEach ($ModuleName In $AllModuleList)
    {
        $BreakingChangeInfo = Get-BreakingChangeInfoOfModule -ModuleName $ModuleName -ArtifactsPath $ArtifactsPath -BreakingChangeInfo $BreakingChangeInfo
    }
    Set-Content -Value $BreakingChangeInfo -Path $ExportCsvPath -Force
}