//
//  LogCollector.swift
//  Construct Messenger
//
//  Collects logs to file for debugging and support
//  Created on 31.01.2026
//

import Foundation
import UIKit

/// Collects logs to a rotating file buffer for debugging
class LogCollector {
    static let shared = LogCollector()
    
    // MARK: - Configuration
    
    /// Maximum log file size (5 MB)
    private let maxFileSize: Int64 = 5 * 1024 * 1024
    
    /// Number of rotated log files to keep
    private let maxRotatedFiles = 3
    
    /// Log directory
    private let logDirectory: URL
    
    /// Current log file
    private let currentLogFile: URL
    
    /// Whether logging to file is enabled
    var isEnabled: Bool {
        get {
            #if DEBUG
            return UserDefaults.standard.bool(forKey: "LogCollector.isEnabled")
            #else
            return false // ALWAYS disabled in production
            #endif
        }
        set {
            #if DEBUG
            // Only allow enabling in DEBUG builds with developer mode
            if DeveloperMode.shared.canEnableLogCollection {
                UserDefaults.standard.set(newValue, forKey: "LogCollector.isEnabled")
                if newValue {
                    Log.info("📝 Log collection enabled", category: "LogCollector")
                } else {
                    Log.info("📝 Log collection disabled", category: "LogCollector")
                }
            }
            #else
            // Production: do nothing, always disabled
            UserDefaults.standard.set(false, forKey: "LogCollector.isEnabled")
            #endif
        }
    }
    
    private let queue = DispatchQueue(label: "cc.konstruct.logcollector", qos: .utility)
    
    // MARK: - Initialization
    
    private init() {
        // Create logs directory in Documents
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logDirectory = documentsPath.appendingPathComponent("Logs", isDirectory: true)
        currentLogFile = logDirectory.appendingPathComponent("current.log")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        
        // Log initial state
        if isEnabled {
            writeSystemInfo()
        }
    }
    
    // MARK: - Logging
    
    /// Append log message to file
    func append(level: String, category: String, message: String) {
        // Production safety: double-check even if isEnabled somehow got set
        
        guard isEnabled else { return }
        guard DeveloperMode.shared.canEnableLogCollection else { return }
        
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let logLine = "[\(timestamp)] [\(level)] [\(category)] \(message)\n"
            
            guard let data = logLine.data(using: .utf8) else { return }
            
            // Check if rotation needed
            if let attributes = try? FileManager.default.attributesOfItem(atPath: self.currentLogFile.path),
               let fileSize = attributes[.size] as? Int64,
               fileSize > self.maxFileSize {
                self.rotateLogFile()
            }
            
            // Append to file
            if FileManager.default.fileExists(atPath: self.currentLogFile.path) {
                if let fileHandle = try? FileHandle(forWritingTo: self.currentLogFile) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    try? fileHandle.close()
                }
            } else {
                try? data.write(to: self.currentLogFile, options: .atomic)
            }
        }
    }
    
    // MARK: - Log Rotation
    
    private func rotateLogFile() {
        // Rotate existing files: current.log → 1.log → 2.log → 3.log (deleted)
        for i in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
            let oldFile = logDirectory.appendingPathComponent("\(i).log")
            let newFile = logDirectory.appendingPathComponent("\(i + 1).log")
            
            try? FileManager.default.removeItem(at: newFile)
            try? FileManager.default.moveItem(at: oldFile, to: newFile)
        }
        
        // Move current to 1.log
        let firstRotated = logDirectory.appendingPathComponent("1.log")
        try? FileManager.default.removeItem(at: firstRotated)
        try? FileManager.default.moveItem(at: currentLogFile, to: firstRotated)
    }
    
    // MARK: - System Info
    
    private func writeSystemInfo() {
        let info = """
        ========================================
        Construct Messenger - Log Session
        ========================================
        App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
        Device: \(UIDevice.current.model)
        iOS Version: \(UIDevice.current.systemVersion)
        Started: \(Date())
        ========================================
        
        """
        
        if let data = info.data(using: .utf8) {
            try? data.write(to: currentLogFile, options: .atomic)
        }
    }
    
    // MARK: - Export
    
    /// Get all log files for export
    func getAllLogFiles() -> [URL] {
        var files: [URL] = []
        
        if FileManager.default.fileExists(atPath: currentLogFile.path) {
            files.append(currentLogFile)
        }
        
        for i in 1...maxRotatedFiles {
            let rotatedFile = logDirectory.appendingPathComponent("\(i).log")
            if FileManager.default.fileExists(atPath: rotatedFile.path) {
                files.append(rotatedFile)
            }
        }
        
        return files.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    
    /// Create combined log archive for sharing
    func createLogArchive() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let archiveName = "construct-logs-\(Date().timeIntervalSince1970).txt"
        let archiveURL = tempDir.appendingPathComponent(archiveName)
        
        var combinedLogs = ""
        
        // Add device info header
        combinedLogs += """
        ========================================
        Construct Messenger Debug Logs
        ========================================
        Exported: \(Date())
        App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
        Device: \(UIDevice.current.model)
        iOS Version: \(UIDevice.current.systemVersion)
        Identifier: \(UIDevice.current.identifierForVendor?.uuidString ?? "Unknown")
        ========================================
        
        
        """
        
        // Combine all log files (oldest to newest)
        let logFiles = getAllLogFiles().reversed()
        for (index, logFile) in logFiles.enumerated() {
            if let content = try? String(contentsOf: logFile, encoding: .utf8) {
                combinedLogs += "=== Log File \(index + 1)/\(logFiles.count): \(logFile.lastPathComponent) ===\n"
                combinedLogs += content
                combinedLogs += "\n\n"
            }
        }
        
        try combinedLogs.write(to: archiveURL, atomically: true, encoding: .utf8)
        return archiveURL
    }
    
    /// Clear all log files
    func clearLogs() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            try? FileManager.default.removeItem(at: self.currentLogFile)
            
            for i in 1...self.maxRotatedFiles {
                let rotatedFile = self.logDirectory.appendingPathComponent("\(i).log")
                try? FileManager.default.removeItem(at: rotatedFile)
            }
            
            Log.info("🗑️ All logs cleared", category: "LogCollector")
            self.writeSystemInfo()
        }
    }
    
    /// Get total size of all logs
    func getTotalLogSize() -> Int64 {
        var totalSize: Int64 = 0
        
        for logFile in getAllLogFiles() {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: logFile.path),
               let size = attributes[.size] as? Int64 {
                totalSize += size
            }
        }
        
        return totalSize
    }
}
