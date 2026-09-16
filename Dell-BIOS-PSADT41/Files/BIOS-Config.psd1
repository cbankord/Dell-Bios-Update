@{
    # One approved Dell executable per package. Exact CIM model names only.
    Models = @('Dell Pro 14 Plus PB14250')
    TargetVersion = '2.1.1'
    MinimumCurrentVersion = '0.0.0' # Set any Dell prerequisite version here.
    FileName = 'Dell_Pro_PA13250.exe'
    SHA256 = 'E169B55698E089F2481A6E5DB0C712F6DC5CFB7F4EE375EB932EE003211A35A74'
    RequireBattery = $true # Set false only for an approved desktop model.
    MinimumBatteryPercent = 50
    MinimumFreeSpaceGB = 1
    BitLockerRebootCount = 1 # Never zero. Validate boot sequence on each model/version.
    EscrowDestination = 'EntraID' # EntraID or ADDS; successful backup required.
    StagedDetectionHours = 24
    # Set true after reviewing Dell release notes, model compatibility and /? help.
    PackageReviewed = $false
}
