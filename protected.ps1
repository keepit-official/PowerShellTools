$results = Search-KeepitSnapshot -Connector 'zltp07' `
      -RootPath '/SharePoint' -ResultSize 5 -Verbose

  # Check what's in the metadata for each result
  $results | ForEach-Object {
      [PSCustomObject]@{
          Name     = $_.Name
          MetaKeys = ($_.Metadata.Keys -join ', ')
      }
  }

  # And check the raw XML if any entry has it
  $results | ForEach-Object {
      if ($_.Metadata.Count -gt 0) {
          $_.Metadata | Format-Table -AutoSize
      }
  }

