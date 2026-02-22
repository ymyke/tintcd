# Releasing tintcd

## Prerequisites

- `gh` CLI authenticated
- PSGallery API key in `$env:PSGALLERY_API_KEY`

## Steps

1. **Run tests**

   ```powershell
   Invoke-Pester
   ```

2. **Bump version** in `tintcd.psd1` (`ModuleVersion`)

3. **Commit and push**

   ```bash
   git add tintcd.psd1 <changed files>
   git commit -m "Description of changes"
   git push
   ```

4. **Create GitHub release**

   ```bash
   gh release create v<version> --title "v<version>" --notes "Release notes here"
   ```

5. **Publish to PSGallery**

   ```powershell
   Publish-Module -Path C:\code\tintcd -NuGetApiKey $env:PSGALLERY_API_KEY
   ```

6. **Verify**

   ```powershell
   Find-Module tintcd
   ```
