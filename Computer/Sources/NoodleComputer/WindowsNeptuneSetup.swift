import Foundation
import ComputerCore

/// Stages the signed package for the next boot. Never replaces the active display driver.
enum WindowsNeptuneSetup {
    typealias Run = (String) async throws -> (output: String, status: Int32)
    typealias Upload = (URL, String) async throws -> Void

    static func powershell(_ script: String) -> String {
        let encoded = script.data(using: .utf16LittleEndian)!.base64EncodedString()
        return "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand \(encoded)"
    }

    static let query = powershell(#"""
        $ErrorActionPreference = 'Stop'
        $device = Get-PnpDevice -Class Display | Where-Object { $_.InstanceId -like 'PCI\VEN_1AF4&DEV_1050*' } | Select-Object -First 1
        if (!$device) { throw 'The VirtIO display device is missing.' }
        $service = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName DEVPKEY_Device_Service).Data
        if ($service -ieq 'VioGpu3D' -and $device.Status -eq 'OK') { exit 0 }
        exit 10
        """#)

    static func prepare(resources: URL, mayStage: Bool = true, run: Run, upload: Upload) async throws -> Bool {
        let current = try await run(query)
        if current.status == 0 { return false }
        guard current.status == 10 else { throw ComputerError("Checking the Windows graphics driver failed: \(current.output)") }
        guard mayStage else { throw ComputerError("The Windows graphics driver did not start after installation.") }
        let folder = resources.appendingPathComponent("neptune-guest")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        guard files.contains(where: { $0.lastPathComponent == "viogpu3d.inf" }) else { throw ComputerError("The Windows 3D driver package is missing.") }
        let made = try await run(#"if not exist C:\noodle\3d mkdir C:\noodle\3d"#)
        guard made.status == 0 else { throw ComputerError("Preparing the Windows graphics driver failed: \(made.output)") }
        for file in files { try await upload(file, "/C/noodle/3d/" + file.lastPathComponent) }
        let staged = try await run(#"pnputil /add-driver C:\noodle\3d\viogpu3d.inf"#)
        guard staged.status == 0 || staged.status == 3010 else {
            throw ComputerError("Staging the Windows graphics driver failed: \(staged.output)")
        }
        // Re-enumerate on the next boot, under SYSTEM. Swapping the active display
        // driver with pnputil's /install has caused a WHEA bugcheck on this platform.
        let mark = try await run(powershell(#"""
            $ErrorActionPreference = 'Stop'
            $task = 'NoodleGraphics-' + [guid]::NewGuid().ToString('N')
            $result = 'C:\noodle\3d\' + $task + '.txt'
            $script = @'
            $ErrorActionPreference = 'Stop'
            try {
                $d = Get-PnpDevice -Class Display | Where-Object { $_.InstanceId -like 'PCI\VEN_1AF4&DEV_1050*' } | Select-Object -First 1
                if (!$d) { throw 'Display device missing' }
                $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)"
                $flags = (Get-ItemProperty -Path $key -Name ConfigFlags -ErrorAction SilentlyContinue).ConfigFlags
                if ($null -eq $flags) { $flags = 0 }
                Set-ItemProperty -Path $key -Name ConfigFlags -Type DWord -Value ($flags -bor 0x20)
                'OK' | Set-Content -LiteralPath '__RESULT__'
            } catch { $_.ToString() | Set-Content -LiteralPath '__RESULT__' }
            '@
            $script = $script.Replace('__RESULT__', $result)
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encoded)
            $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
            try {
                Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force | Out-Null
                Start-ScheduledTask -TaskName $task
                $deadline = [DateTime]::UtcNow.AddSeconds(60)
                while (!(Test-Path -LiteralPath $result)) {
                    if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out preparing the next graphics boot.' }
                    Start-Sleep -Milliseconds 200
                }
                $answer = (Get-Content -LiteralPath $result -Raw).Trim()
                if ($answer -ne 'OK') { throw $answer }
            } finally {
                Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $result -ErrorAction SilentlyContinue
            }
            """#))
        guard mark.status == 0 else { throw ComputerError("Preparing the next Windows graphics boot failed: \(mark.output)") }
        return true
    }
}

