<#
.SYNOPSIS
    Builds a spreadsheet of AWS GovCloud EC2 Reserved Instance market rates.

.DESCRIPTION
    awspricer queries the public AWS Price List Bulk API (NO AWS credentials
    required) and extracts EC2 Reserved Instance pricing for the AWS GovCloud (US)
    regions. By default it captures the 1-year, All Upfront, *standard* offering
    class rate for each instance configuration and writes the results to a CSV.

    Originally written in 2015/2016 for the FAA / CSGov hybrid-cloud contract,
    this version is modernized for the current AWS Price List API:
      * Uses the per-region offer files (~200 MB CSV) instead of the full
        AmazonEC2 offer file (now ~8.6 GB) so it runs on a normal workstation.
      * Handles BOTH GovCloud regions (us-gov-west-1 and us-gov-east-1). The
        single "AWS GovCloud (US)" region the original script filtered on no
        longer exists; locations are now "AWS GovCloud (US-West/US-East)".
      * Tolerates AWS's mixed value formats ("1yr"/"1 yr",
        "All Upfront"/"AllUpfront").
      * Surfaces the OfferingClass (standard vs convertible) attribute that AWS
        added after the original was written.

.PARAMETER Regions
    GovCloud region codes to include. Default: us-gov-west-1 and us-gov-east-1.

.PARAMETER LeaseContractLength
    Reserved term length to match (whitespace-insensitive). Default: "1yr".

.PARAMETER PurchaseOption
    Purchase option to match (whitespace-insensitive). Default: "All Upfront".

.PARAMETER OfferingClass
    standard, convertible, or all. Default: standard (the apples-to-apples
    "market rate" comparison for contract cost verification).

.PARAMETER OutputPath
    CSV output file. Default: .\govcloud-ec2-pricing.csv

.PARAMETER WorkingDirectory
    Download cache directory. Default: .\awsworkingdirectory

.PARAMETER OfferCode
    AWS service offer code. Default: AmazonEC2. (Attribute extraction below is
    EC2-specific; other services can be added by mapping their columns.)

.EXAMPLE
    .\awspricer.ps1
    Writes 1yr All Upfront standard RI rates for both GovCloud regions.

.EXAMPLE
    .\awspricer.ps1 -Regions us-gov-west-1 -OfferingClass all -OutputPath west.csv
#>
[CmdletBinding()]
param(
    [string[]] $Regions             = @('us-gov-west-1', 'us-gov-east-1'),
    [string]   $LeaseContractLength = '1yr',
    [string]   $PurchaseOption      = 'All Upfront',
    [ValidateSet('standard', 'convertible', 'all')]
    [string]   $OfferingClass       = 'standard',
    [string]   $OutputPath          = '.\govcloud-ec2-pricing.csv',
    [string]   $WorkingDirectory    = '.\awsworkingdirectory',
    [string]   $OfferCode           = 'AmazonEC2'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # large Invoke-WebRequest downloads are much faster without the progress bar
$PriceApiRoot          = 'https://pricing.us-east-1.amazonaws.com'

# Whitespace-insensitive comparison helper. AWS now ships both "1yr"/"1 yr" and
# "All Upfront"/"AllUpfront" in the same file, so we strip spaces before matching.
function Normalize-Term([string] $s) { return ($s -replace '\s', '') }

# -----------------------------------------------------------------------------
# 1. Discover the per-region offer files via the (post-2016) region index.
# -----------------------------------------------------------------------------
Write-Host 'Fetching AWS price offer index...'
$index = Invoke-RestMethod -Uri "$PriceApiRoot/offers/v1.0/aws/index.json" -UseBasicParsing
$offer = $index.offers.$OfferCode
if (-not $offer) { throw "Offer code '$OfferCode' not found in the AWS price index." }
if (-not $offer.currentRegionIndexUrl) {
    throw "No currentRegionIndexUrl for $OfferCode; the region-index API is unavailable."
}

Write-Host "Fetching $OfferCode region index..."
$regionIndex = Invoke-RestMethod -Uri ($PriceApiRoot + $offer.currentRegionIndexUrl) -UseBasicParsing

if (-not (Test-Path $WorkingDirectory)) {
    New-Item -ItemType Directory -Path $WorkingDirectory | Out-Null
}

$wantLease    = Normalize-Term $LeaseContractLength
$wantPurchase = Normalize-Term $PurchaseOption
$allRows      = New-Object System.Collections.Generic.List[object]

foreach ($regionCode in $Regions) {
    $regionEntry = $regionIndex.regions.$regionCode
    if (-not $regionEntry) {
        Write-Warning "Region '$regionCode' not found in the $OfferCode region index; skipping."
        continue
    }

    # The region offer is published as both index.json and index.csv. We use the
    # CSV (each row is one product x term x price-dimension with named columns),
    # which is far easier and lighter to process in PowerShell than nested JSON.
    $csvUrlPath = $regionEntry.currentVersionUrl -replace 'index\.json$', 'index.csv'
    $csvUrl     = $PriceApiRoot + $csvUrlPath
    $version    = ($regionEntry.currentVersionUrl -split '/')[5]   # /offers/v1.0/aws/<offer>/<version>/<region>/index.json
    $cacheCsv   = Join-Path $WorkingDirectory ('{0}-{1}-{2}.csv' -f $OfferCode, $regionCode, $version)

    if (Test-Path $cacheCsv) {
        Write-Host "Using cached price file: $cacheCsv"
    }
    else {
        Write-Host "Downloading $OfferCode $regionCode pricing (version $version)..."
        Invoke-WebRequest -Uri $csvUrl -OutFile $cacheCsv -UseBasicParsing
    }

    # -------------------------------------------------------------------------
    # 2. Stream the CSV: skip the 5-line metadata preamble, keep the header, and
    #    coarse-filter to Reserved rows so we only materialize a small subset.
    # -------------------------------------------------------------------------
    Write-Host "Parsing $regionCode price file..."
    $reader = [System.IO.StreamReader]::new($cacheCsv)
    try {
        $header = $null
        $kept   = New-Object System.Collections.Generic.List[string]
        $lineNo = 0
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineNo++
            if ($lineNo -le 5) { continue }                    # metadata preamble
            if ($lineNo -eq 6) { $header = $line; continue }   # column header row
            if ($line -like '*Reserved*') { $kept.Add($line) } # cheap coarse pre-filter
        }
    }
    finally {
        $reader.Dispose()
    }

    if (-not $header)      { Write-Warning "No header row in $cacheCsv; skipping."; continue }
    if ($kept.Count -eq 0) { Write-Warning "No Reserved rows found for $regionCode."; continue }

    $rows = @($header) + $kept | ConvertFrom-Csv

    # -------------------------------------------------------------------------
    # 3. Precise filter. For "All Upfront" RIs the entire 1-year cost is the
    #    single price dimension with Unit = "Quantity" (the recurring Hrs rate is
    #    $0.00), so that row is the upfront fee we want.
    # -------------------------------------------------------------------------
    $matches = $rows | Where-Object {
        $_.TermType -eq 'Reserved' -and
        $_.Unit     -eq 'Quantity' -and
        (Normalize-Term $_.LeaseContractLength) -eq $wantLease -and
        (Normalize-Term $_.PurchaseOption)      -eq $wantPurchase -and
        ($OfferingClass -eq 'all' -or $_.OfferingClass -eq $OfferingClass)
    }

    Write-Host ('  {0} matching Reserved offers in {1}' -f @($matches).Count, $regionCode)

    foreach ($r in $matches) {
        $perYear = 0.0
        [void][double]::TryParse($r.PricePerUnit, [ref] $perYear)
        $allRows.Add([pscustomobject][ordered]@{
            'SKU'                  = $r.SKU
            'Region Code'          = $r.'Region Code'
            'Location'             = $r.Location
            'Product Family'       = $r.'Product Family'   # "Compute Instance" vs "Dedicated Host" (priced per host)
            'Tenancy'              = $r.Tenancy
            'Instance Type'        = $r.'Instance Type'
            'Instance Family'      = $r.'Instance Family'
            '# virt cores'         = $r.vCPU
            'Host CPU'             = $r.'Physical Processor'
            'Host CPU Clock Speed' = $r.'Clock Speed'
            'Memory'               = $r.Memory
            'OS'                   = $r.'Operating System'
            'License'              = $r.'License Model'
            'Bundled SW'           = $r.'Pre Installed S/W'
            'Offering Class'       = $r.OfferingClass
            'Lease'                = $r.LeaseContractLength
            'Purchase Option'      = $r.PurchaseOption
            'Upfront Cost (1yr)'   = $perYear
            'Per Month Cost'       = [math]::Round($perYear / 12, 2)
        })
    }
}

# -----------------------------------------------------------------------------
# 4. Output.
# -----------------------------------------------------------------------------
if ($allRows.Count -eq 0) {
    Write-Warning 'No matching GovCloud Reserved Instance prices found. Nothing written.'
    return
}

$allRows |
    Sort-Object 'Region Code', 'Instance Family', 'Instance Type', 'OS' |
    Export-Csv -Path $OutputPath -NoTypeInformation

Write-Host ('Wrote {0} rows to {1}' -f $allRows.Count, $OutputPath)
$allRows | Select-Object -First 10 | Format-Table -AutoSize
