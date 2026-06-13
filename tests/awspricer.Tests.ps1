#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

<#
    Offline tests for awspricer.ps1.

    The script's only external dependencies are two web calls (Invoke-RestMethod
    for the JSON indexes, Invoke-WebRequest for the per-region CSV download).
    These tests mock all three I/O boundaries so the parse/filter/output logic
    runs end-to-end with no network access and no multi-hundred-MB downloads.
#>

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'awspricer.ps1'

    # A region offer CSV in the exact shape awspricer expects: 5 metadata
    # preamble lines, a header row, then data rows. Includes rows that should
    # survive filtering and rows that should be dropped, so we exercise both the
    # coarse "*Reserved*" pre-filter and the precise TermType/Unit/term filter.
    $script:FixtureCsv = @'
"FormatVersion","20260101"
"Disclaimer","This pricing list is for informational purposes only."
"Publication Date","2026-01-01T00:00:00Z"
"Version","20260101000000"
"OfferCode","AmazonEC2"
"SKU","OfferTermCode","RateCode","TermType","PriceDescription","Unit","PricePerUnit","Currency","LeaseContractLength","PurchaseOption","OfferingClass","Product Family","serviceCode","Location","Region Code","Instance Type","Instance Family","vCPU","Physical Processor","Clock Speed","Memory","Operating System","License Model","Pre Installed S/W","Tenancy"
"SKU-MATCH","TERM1","RATE1","Reserved","Upfront Fee","Quantity","1200.00","USD","1yr","All Upfront","standard","Compute Instance","AmazonEC2","AWS GovCloud (US-West)","us-gov-west-1","m5.large","m5","2","Intel Xeon","2.5 GHz","8 GiB","Linux","No License required","NA","Shared"
"SKU-MATCH","TERM1","RATE2","Reserved","Hrs","Hrs","0.0000000000","USD","1yr","All Upfront","standard","Compute Instance","AmazonEC2","AWS GovCloud (US-West)","us-gov-west-1","m5.large","m5","2","Intel Xeon","2.5 GHz","8 GiB","Linux","No License required","NA","Shared"
"SKU-CONV","TERM2","RATE3","Reserved","Upfront Fee","Quantity","999.00","USD","1yr","All Upfront","convertible","Compute Instance","AmazonEC2","AWS GovCloud (US-West)","us-gov-west-1","m5.xlarge","m5","4","Intel Xeon","2.5 GHz","16 GiB","Linux","No License required","NA","Shared"
"SKU-3YR","TERM3","RATE4","Reserved","Upfront Fee","Quantity","3000.00","USD","3yr","All Upfront","standard","Compute Instance","AmazonEC2","AWS GovCloud (US-West)","us-gov-west-1","m5.large","m5","2","Intel Xeon","2.5 GHz","8 GiB","Linux","No License required","NA","Shared"
"SKU-OND","TERM4","RATE5","OnDemand","On Demand","Hrs","0.1000000000","USD","","","","Compute Instance","AmazonEC2","AWS GovCloud (US-West)","us-gov-west-1","m5.large","m5","2","Intel Xeon","2.5 GHz","8 GiB","Linux","No License required","NA","Shared"
'@
}

Describe 'awspricer.ps1' {

    It 'exists and parses without syntax errors' {
        $ScriptPath | Should -Exist
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It 'exposes comment-based help' {
        $help = Get-Help $ScriptPath
        $help.Synopsis | Should -Match 'GovCloud'
    }

    Context 'end-to-end with mocked AWS Price List API' {

        BeforeEach {
            $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("awspricer-test-" + [System.Guid]::NewGuid())
            $script:OutCsv  = Join-Path $WorkDir 'out.csv'

            # index.json -> points to a region index; region index -> points to a
            # version-stamped CSV URL whose 6th path segment is the cache version.
            Mock Invoke-RestMethod {
                if ($Uri -like '*/index.json') {
                    return [pscustomobject]@{
                        offers = [pscustomobject]@{
                            AmazonEC2 = [pscustomobject]@{
                                currentRegionIndexUrl = '/offers/v1.0/aws/AmazonEC2/current/region_index.json'
                            }
                        }
                    }
                }
                # region index
                return [pscustomobject]@{
                    regions = [pscustomobject]@{
                        'us-gov-west-1' = [pscustomobject]@{
                            currentVersionUrl = '/offers/v1.0/aws/AmazonEC2/20260101/us-gov-west-1/index.json'
                        }
                    }
                }
            } -ParameterFilter { $true }

            # Download = drop the fixture CSV at the requested -OutFile path.
            Mock Invoke-WebRequest {
                Set-Content -Path $OutFile -Value $FixtureCsv -Encoding utf8
            }
        }

        AfterEach {
            if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
        }

        It 'writes only the matching 1yr All Upfront standard offer' {
            & $ScriptPath -Regions us-gov-west-1 -WorkingDirectory $WorkDir -OutputPath $OutCsv 6>$null

            $OutCsv | Should -Exist
            $result = Import-Csv $OutCsv
            @($result).Count                | Should -Be 1
            $result.SKU                     | Should -Be 'SKU-MATCH'
            $result.'Instance Type'         | Should -Be 'm5.large'
            $result.'Offering Class'        | Should -Be 'standard'
            [double]$result.'Upfront Cost (1yr)' | Should -Be 1200
            [double]$result.'Per Month Cost'     | Should -Be 100
        }

        It 'includes convertible offers when -OfferingClass all is passed' {
            & $ScriptPath -Regions us-gov-west-1 -OfferingClass all -WorkingDirectory $WorkDir -OutputPath $OutCsv 6>$null

            $result = @(Import-Csv $OutCsv)
            $result.Count | Should -Be 2
            ($result.SKU | Sort-Object) | Should -Be @('SKU-CONV', 'SKU-MATCH')
        }

        It 'matches a different lease term whitespace-insensitively' {
            & $ScriptPath -Regions us-gov-west-1 -LeaseContractLength '3 yr' -WorkingDirectory $WorkDir -OutputPath $OutCsv 6>$null

            $result = @(Import-Csv $OutCsv)
            $result.Count           | Should -Be 1
            $result.SKU             | Should -Be 'SKU-3YR'
        }

        It 'reuses a cached price file instead of re-downloading' {
            & $ScriptPath -Regions us-gov-west-1 -WorkingDirectory $WorkDir -OutputPath $OutCsv 6>$null
            & $ScriptPath -Regions us-gov-west-1 -WorkingDirectory $WorkDir -OutputPath $OutCsv 6>$null

            # Two runs, but only the first should have triggered a download.
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        }

        It 'warns and skips a region missing from the index' {
            & $ScriptPath -Regions us-gov-east-1 -WorkingDirectory $WorkDir -OutputPath $OutCsv -WarningAction SilentlyContinue 6>$null
            $OutCsv | Should -Not -Exist
        }
    }
}
