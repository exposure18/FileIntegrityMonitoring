Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# === SMTP CONFIGURATION ===
$SMTPServer = "smtp.gmail.com"
$SMTPPort = 587
$Sender = "sender email here!!"
$Recipient = "receiving email here!!"
$AppPassword = "google app password"

# === PATH SETUP ===
$rootPath = "C:\Users\Ricky Rodrigues\Desktop\FIM PowerShell"
$baselineFolder = Join-Path $rootPath "Baseline"
$baselineFile = Join-Path $rootPath "Baseline.txt"
$logFile = Join-Path $rootPath "FIMLogs.txt"

# === GLOBAL SHARED VARIABLE ===
$global:pausedRef = [ref]$false

# === FORM SETUP ===
$form = New-Object System.Windows.Forms.Form
$form.Text = "FIM - GUI"
$form.Size = New-Object System.Drawing.Size(1100, 780)
$form.StartPosition = "CenterScreen"
$form.BackColor = 'Black'

$title = New-Object System.Windows.Forms.Label
$title.Text = "File Integrity Monitoring (FIM)"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = 'White'
$title.AutoSize = $true
$title.Top = 10
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "Ensure Your Files Are Safe and Unchanged"
$subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Italic)
$subtitle.ForeColor = 'Silver'
$subtitle.AutoSize = $true
$subtitle.Top = 55
$form.Controls.Add($subtitle)

$outputBox = New-Object System.Windows.Forms.RichTextBox
$outputBox.Size = New-Object System.Drawing.Size(1050, 500)
$outputBox.Location = New-Object System.Drawing.Point(20, 150)
$outputBox.Font = New-Object System.Drawing.Font("Consolas", 10)
$outputBox.BackColor = 'Black'
$outputBox.ForeColor = 'White'
$form.Controls.Add($outputBox)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Status: Idle"
$statusLabel.Location = New-Object System.Drawing.Point(20, 680)
$statusLabel.Size = New-Object System.Drawing.Size(600, 20)
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Italic)
$statusLabel.ForeColor = 'White'
$form.Controls.Add($statusLabel)

function Write-Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] $msg"
    $form.Invoke([Action]{ $outputBox.AppendText("$entry`r`n") })
}

function Collect-Baseline {
    if (Test-Path $baselineFile) { Remove-Item $baselineFile -Force }

    $files = Get-ChildItem -Path $baselineFolder
    foreach ($f in $files) {
        $hash = Get-FileHash -Path $f.FullName -Algorithm SHA512
        "$($f.FullName)|$($hash.Hash)" | Out-File -FilePath $baselineFile -Append
        Write-Log "Hashed: $($f.Name) [$($hash.Hash)]"
    }

    Write-Log "✔ Baseline collection completed."
    $statusLabel.Text = "Status: Baseline collected"
}

function Start-Monitoring {
    if (-Not (Test-Path $baselineFile)) {
        Write-Log "❌ Baseline.txt not found. Please collect baseline first."
        return
    }

    $statusLabel.Text = "Status: Monitoring..."
    $baselineData = @{}
    Get-Content $baselineFile | ForEach-Object {
        $parts = $_ -split "\|"
        $baselineData[$parts[0]] = $parts[1]
    }

    $activeSnapshot = @{}
    $tempNewFiles = @{}

    foreach ($file in Get-ChildItem -Path $baselineFolder) {
        $activeSnapshot[$file.FullName] = (Get-FileHash -Path $file.FullName -Algorithm SHA512).Hash
    }

    $monitorScript = {
        param(
            $baselineData, $baselineFolder, $outputBoxRef, $formRef, $statusRef,
            [ref]$pausedRef, [ref]$snapshotRef, [ref]$tempNewRef,
            $SMTPServer, $SMTPPort, $Sender, $AppPassword, $Recipient
        )

        function Send-Log { param($msg, $type, $path)
            $outputBoxRef.Invoke([Action]{ $outputBoxRef.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $msg`r`n") })
            try {
                $fileName = Split-Path $path -Leaf
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $eventID = Get-Date -Format "yyyyMMddHHmmss"
                $hash = "Unavailable"
                if (Test-Path $path) {
                    $hash = (Get-FileHash -Path $path -Algorithm SHA512).Hash
                }

                $subject = "⚠️ FIM Alert: $type"
                $body = @"
<html>
<body style='font-family:Segoe UI; font-size:14px;'>
<b>FIM Alert - $type</b><br><br>
<b>File Name:</b> $fileName<br>
<b>Full Path:</b> $path<br>
<b>Timestamp:</b> $timestamp<br>
<b>Event ID:</b> EVT-$eventID<br>
<b>Hash Method:</b> SHA512<br>
<b>Hash Value:</b><br>
$hash<br><br>
If you did not authorize this file action, please investigate.<br><br>
<b>- FIM PowerShell System</b>
</body>
</html>
"@

                $mail = New-Object System.Net.Mail.MailMessage
                $mail.From = "$Sender"
                $mail.To.Add("$Recipient")
                $mail.Subject = $subject
                $mail.Body = $body
                $mail.IsBodyHtml = $true

                $smtp = New-Object System.Net.Mail.SmtpClient($SMTPServer, $SMTPPort)
                $smtp.EnableSsl = $true
                $smtp.Credentials = New-Object System.Net.NetworkCredential($Sender, $AppPassword)

                $smtp.Send($mail)
                $outputBoxRef.Invoke([Action]{ $outputBoxRef.AppendText("[SMTP] ✅ Email sent: $type - $fileName`r`n") })
            } catch {
                $outputBoxRef.Invoke([Action]{ $outputBoxRef.AppendText("[SMTP] ❌ Failed to send email: $($_.Exception.Message)`r`n") })
            }
        }

        while ($true) {
            Start-Sleep -Seconds 2
            if ($pausedRef.Value) {
                $outputBoxRef.Invoke([Action]{ $outputBoxRef.AppendText("[INFO] Monitoring is paused.`r`n") })
                continue
            }

            $currentFiles = Get-ChildItem -Path $baselineFolder
            foreach ($file in $currentFiles) {
                $path = $file.FullName
                $hash = (Get-FileHash -Path $path -Algorithm SHA512).Hash

                if ($snapshotRef.Value.ContainsKey($path)) {
                    if ($snapshotRef.Value[$path] -ne $hash) {
                        Send-Log "Modified: $path" "File Modified" $path
                        $snapshotRef.Value[$path] = $hash
                    }
                } elseif ($baselineData.ContainsKey($path)) {
                    if ($baselineData[$path] -eq $hash) {
                        Send-Log "Restored: $path" "File Restored" $path
                    } else {
                        Send-Log "New file (baseline mismatch): $path" "New File Added" $path
                        $tempNewRef.Value[$path] = $true
                    }
                    $snapshotRef.Value[$path] = $hash
                } else {
                    Send-Log "New file: $path" "New File Added" $path
                    $snapshotRef.Value[$path] = $hash
                    $tempNewRef.Value[$path] = $true
                }
            }

            foreach ($path in @($snapshotRef.Value.Keys)) {
                if (-not (Test-Path $path)) {
                    if ($baselineData.ContainsKey($path)) {
                        Send-Log "Deleted: $path" "File Deleted" $path
                    } elseif ($tempNewRef.Value.ContainsKey($path)) {
                        Send-Log "Deleted (Not in Baseline): $path" "Untracked File Deleted" $path
                        $tempNewRef.Value.Remove($path)
                    }
                    $snapshotRef.Value.Remove($path)
                }
            }
        }
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript($monitorScript)
    $ps.AddArgument($baselineData)
    $ps.AddArgument($baselineFolder)
    $ps.AddArgument($outputBox)
    $ps.AddArgument($form)
    $ps.AddArgument($statusLabel)
    $ps.AddArgument($global:pausedRef)
    $ps.AddArgument([ref]$activeSnapshot)
    $ps.AddArgument([ref]$tempNewFiles)
    $ps.AddArgument($SMTPServer)
    $ps.AddArgument($SMTPPort)
    $ps.AddArgument($Sender)
    $ps.AddArgument($AppPassword)
    $ps.AddArgument($Recipient)
    $ps.BeginInvoke()
}

function Toggle-Pause {
    $global:pausedRef.Value = -not $global:pausedRef.Value
    if ($global:pausedRef.Value) {
        $statusLabel.Text = "Status: Monitoring Paused"
        Write-Log "⏸ Monitoring paused."
    } else {
        $statusLabel.Text = "Status: Monitoring..."
        Write-Log "▶ Monitoring resumed."
    }
}

function Download-Log {
    $outputBox.Text | Out-File -FilePath $logFile -Encoding UTF8
    Write-Log "✔ Log saved to: $logFile"
}

function New-Button($text, $x, $color, $callback) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Size = New-Object System.Drawing.Size(150, 40)
    $btn.Location = New-Object System.Drawing.Point($x, 110)
    $btn.BackColor = $color
    $btn.ForeColor = 'White'
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btn.Add_Click($callback)
    $form.Controls.Add($btn)
}

New-Button "Collect Baseline" 20 'Green' { Collect-Baseline }
New-Button "Start Monitoring" 200 'DarkOrange' { Start-Monitoring }
New-Button "Pause/Resume" 380 'RoyalBlue' { Toggle-Pause }
New-Button "Exit" 560 'Maroon' { $form.Close() }

$btnDownload = New-Object System.Windows.Forms.Button
$btnDownload.Text = "Download Log"
$btnDownload.Size = New-Object System.Drawing.Size(150, 40)
$btnDownload.Location = New-Object System.Drawing.Point(920, 670)
$btnDownload.BackColor = 'DimGray'
$btnDownload.ForeColor = 'White'
$btnDownload.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnDownload.Add_Click({ Download-Log })
$form.Controls.Add($btnDownload)

$form.Add_Shown({
    $title.Left = ($form.ClientSize.Width - $title.PreferredWidth) / 2
    $subtitle.Left = ($form.ClientSize.Width - $subtitle.PreferredWidth) / 2
    $form.Activate()
})

$form.Topmost = $true
[void]$form.ShowDialog()
