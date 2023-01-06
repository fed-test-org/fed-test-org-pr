# Authenticate to Azure Subscription
# Connect-AzAccount -Environment AzureCloud -Subscription <subscription_guid>
$location                 = 'eastus'
$tfbackend_rg_name        = 'federatedtest'
$tfbackend_sa_name        = 'tfstateemc'
$tfbackend_container_name = 'tfstate'
$tf_sp_name               = 'devprtest-org-tf-gh-sp'
$ghUsername               = 'mcarter106'
$ghPAT                    = ''
$ghOrgName                = 'fed-test-org'
$ghRepoName               = 'fed-test-org-pr'

$subscriptionId = (Get-AzContext).Subscription.Id
$tenantId = (Get-AzContext).Tenant.Id

####################### CREATE SERVICE PRINCIPAL AND FEDERATED CREDENTIAL #######################
if (-Not ($sp = Get-AzADServicePrincipal -DisplayName $tf_sp_name -ErrorAction 'SilentlyContinue'))
{
    $sp = New-AzADServicePrincipal -DisplayName $tf_sp_name -ErrorAction 'Stop'
}

$app = Get-AzADApplication -ApplicationId $sp.AppId

if (-Not (Get-AzADAppFederatedCredential -ApplicationObjectId $app.Id))
{
    $params = @{
        ApplicationObjectId = $app.Id
        Audience            = 'api://AzureADTokenExchange'
        Issuer              = 'https://token.actions.githubusercontent.com'
        Name                = "$tf_sp_name"
        Subject             = "repo:$ghOrgName/${ghRepoName}:pull_request"
    }
    $cred = New-AzADAppFederatedCredential @params
}

####################### CREATE BACKEND RESOURCES #######################
if (-Not (Get-AzResourceGroup -Name $tfbackend_rg_name -Location $location -ErrorAction 'SilentlyContinue'))
{
    New-AzResourceGroup -Name $tfbackend_rg_name -Location $location -ErrorAction 'Stop'
}

if (-Not ($sa = Get-AzStorageAccount -ResourceGroupName $tfbackend_rg_name -Name $tfbackend_sa_name -ErrorAction 'SilentlyContinue'))
{
    $sa = New-AzStorageAccount -ResourceGroupName $tfbackend_rg_name -Name $tfbackend_sa_name -Location $location -SkuName 'Standard_GRS' -AllowBlobPublicAccess $false -ErrorAction 'Stop'
}

if (-Not (Get-AzStorageContainer -Name $tfbackend_container_name -Context $sa.Context -ErrorAction 'SilentlyContinue'))
{
    $container = New-AzStorageContainer -Name $tfbackend_container_name -Context $sa.Context -ErrorAction 'Stop'
}

if (-Not (Get-AzRoleAssignment -ServicePrincipalName $sp.AppId -Scope "/subscriptions/$subscriptionId" -RoleDefinitionName 'Contributor' -ErrorAction 'SilentlyContinue'))
{
    $subContributorRA = New-AzRoleAssignment -ApplicationId $sp.AppId -Scope "/subscriptions/$subscriptionId" -RoleDefinitionName 'Contributor' -ErrorAction 'Stop'
}

if (-Not (Get-AzRoleAssignment -ServicePrincipalName $sp.AppId -Scope $sa.Id -RoleDefinitionName 'Storage Blob Data Contributor' -ErrorAction 'SilentlyContinue'))
{
    $saBlobContributorRA = New-AzRoleAssignment -ApplicationId $sp.AppId -Scope $sa.Id -RoleDefinitionName 'Storage Blob Data Contributor' -ErrorAction 'Stop'
}

####################### CREATE GitHub Environment & Secrets #######################
if (-Not [string]::IsNullOrEmpty($ghPAT))
{
    $headers = @{"Authorization"="Basic $([System.Convert]::ToBase64String([System.Text.Encoding]::Ascii.GetBytes("${ghUsername}:$ghPAT")))"}
    $repoId = (Invoke-WebRequest -Uri "https://api.github.com/repos/$ghOrgName/$ghRepoName" -Headers $headers | ConvertFrom-Json).Id

    $orgPublicKeyObj = Invoke-WebRequest -Uri "https://api.github.com/orgs/$ghOrgName/actions/secrets/public-key" -Headers $headers | ConvertFrom-Json
    $orgPublicKey = $orgPublicKeyObj.key
    $orgPublicKeyId = $orgPublicKeyObj.key_id

    $secrets = @{
        AZURE_CLIENT_ID       = $app.AppId
        AZURE_SUBSCRIPTION_ID = $subscriptionId
        AZURE_TENANT_ID       = $tenantId
    }

    $response = @()
    foreach ($secret in $secrets.GetEnumerator())
    {
        $encryptedValue = ConvertTo-SodiumEncryptedString -Text $secret.Value -PublicKey $orgPublicKey
        $clientIdBody = @{
            encrypted_value = $encryptedValue
            key_id          = $orgPublicKeyId
            visibility      = 'selected'
        } | ConvertTo-Json

        $response += Invoke-WebRequest -Uri " https://api.github.com/orgs/$ghOrgName/actions/secrets/$($secret.Key)" -Method Put -Headers $headers -Body $clientIdBody
        $response += Invoke-WebRequest -Uri "https://api.github.com/orgs/$ghOrgName/actions/secrets/$($secret.Key)/repositories/$repoId" -Method Put -Headers $headers
    }
}
else {
    Write-Host 'No PAT passed in - no GitHub secrets created.' -ForegroundColor 'Cyan'
}
Write-Host "Application/Client ID is: $($app.AppId)" -ForegroundColor 'Green'
