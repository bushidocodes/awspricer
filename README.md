# awspricer

_You don't want to negotiate the price of simple things you buy every day. -Jeff Bezos_

_doveryai no proveryai (trust, but verify) - Ronald Reagan_

-------
In 2015, the Federal Aviation Administration signed a multiyear partnership with CSGov to provide brokered hybrid cloud services, including public and government community cloud services brokered
from Amazon Web Services and Microsoft Azure.

In order to verify the cost effectiveness of the contract vehicle, the FAA developed awspricer to be able to dynamically build a spreadsheet of market rates for cloud services in the AWS GovCloud region.

To ensure that the package can be run by non-technical personnel on a standard FAA workstation, awspricer is written in PowerShell.

-------

## What it does

`awspricer.ps1` queries the **public AWS Price List Bulk API** (no AWS account or
credentials required) and extracts EC2 Reserved Instance pricing for the AWS
GovCloud (US) regions. By default it captures the **1-year, All Upfront,
standard** offering-class rate for every instance configuration and writes them
to `govcloud-ec2-pricing.csv`.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+ (no extra modules).
- Outbound HTTPS access to `pricing.us-east-1.amazonaws.com`.
- ~250 MB free disk per region for the cached price file.

## Usage

```powershell
# Both GovCloud regions, 1yr All Upfront standard RIs -> govcloud-ec2-pricing.csv
.\awspricer.ps1

# One region, include convertible + standard, custom output file
.\awspricer.ps1 -Regions us-gov-west-1 -OfferingClass all -OutputPath west.csv

# A different term (whitespace-insensitive matching)
.\awspricer.ps1 -LeaseContractLength 3yr -PurchaseOption "Partial Upfront"
```

Run `Get-Help .\awspricer.ps1 -Full` for all parameters.

## Output columns

`SKU, Region Code, Location, Product Family, Tenancy, Instance Type,
Instance Family, # virt cores, Host CPU, Host CPU Clock Speed, Memory, OS,
License, Bundled SW, Offering Class, Lease, Purchase Option,
Upfront Cost (1yr), Per Month Cost`

For All Upfront RIs the whole term cost is the single `Quantity` ("Upfront Fee")
price dimension; `Per Month Cost` is that figure divided by 12. Note that some
rows are `Product Family = "Dedicated Host"` (priced per host, with
`Tenancy = Reserved`) rather than per-instance — the column makes them easy to
filter.

## 2026 modernization notes

The original 2016 script no longer ran against today's API. This version fixes:

1. **Per-region files instead of the 8.6 GB monolith.** The full `AmazonEC2`
   offer file is now ~8.6 GB and cannot be parsed on a normal workstation. We
   use the per-region offer file (~200 MB CSV) discovered via the
   `currentRegionIndexUrl` index that AWS added after 2016.
2. **Both GovCloud regions.** The single `"AWS GovCloud (US)"` location the
   original filtered on no longer exists; pricing is now published per region as
   `"AWS GovCloud (US-West)"` (`us-gov-west-1`) and `"AWS GovCloud (US-East)"`
   (`us-gov-east-1`).
3. **Tolerant term matching.** AWS now ships mixed value formats in the same
   file (`"1yr"`/`"1 yr"`, `"All Upfront"`/`"AllUpfront"`); matching is
   whitespace-insensitive so no offers are silently dropped.
4. **OfferingClass.** The `standard` vs `convertible` distinction (added after
   2016) is surfaced as a column and selectable via `-OfferingClass`.