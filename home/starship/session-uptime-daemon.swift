import Foundation

// Configuration
let lockThresholdSeconds: TimeInterval = {
  if let envValue = ProcessInfo.processInfo.environment["SESSION_LOCK_THRESHOLD"],
    let seconds = TimeInterval(envValue)
  {
    return seconds
  }
  return 1800  // Default: 30 minutes
}()

let stateDir = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent(".local/state/starship-prompt")
let lockFile = stateDir.appendingPathComponent("lock")
let startFile = stateDir.appendingPathComponent("start")

func ensureStateDir() {
  try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
}

func writeTimestamp(to file: URL) {
  let timestamp = String(Int(Date().timeIntervalSince1970))
  try? timestamp.write(to: file, atomically: true, encoding: .utf8)
}

func readTimestamp(from file: URL) -> TimeInterval? {
  guard let contents = try? String(contentsOf: file, encoding: .utf8),
    let timestamp = TimeInterval(contents.trimmingCharacters(in: .whitespacesAndNewlines))
  else {
    return nil
  }
  return timestamp
}

func handleLock() {
  writeTimestamp(to: lockFile)
  print("[\(Date())] Screen locked - timestamp written")
}

func handleUnlock() {
  let now = Date().timeIntervalSince1970

  if let lockTime = readTimestamp(from: lockFile) {
    let lockedDuration = now - lockTime
    print(
      "[\(Date())] Screen unlocked - locked for \(Int(lockedDuration))s (threshold: \(Int(lockThresholdSeconds))s)"
    )

    if lockedDuration > lockThresholdSeconds {
      writeTimestamp(to: startFile)
      print("[\(Date())] New session started (exceeded threshold)")
    }
  } else {
    // No lock file exists, start new session
    writeTimestamp(to: startFile)
    print("[\(Date())] New session started (no previous lock)")
  }

  // Clean up lock file
  try? FileManager.default.removeItem(at: lockFile)
}

func initializeSession() {
  ensureStateDir()

  // If no start file exists, create one
  if !FileManager.default.fileExists(atPath: startFile.path) {
    writeTimestamp(to: startFile)
    print("[\(Date())] Initial session start")
  } else {
    print("[\(Date())] Existing session found")
  }
}

// Main
print("Session Uptime Daemon starting...")
print("Lock threshold: \(Int(lockThresholdSeconds)) seconds")
print("State directory: \(stateDir.path)")

initializeSession()

let dnc = DistributedNotificationCenter.default()

dnc.addObserver(
  forName: NSNotification.Name("com.apple.screenIsLocked"),
  object: nil,
  queue: .main
) { _ in
  handleLock()
}

dnc.addObserver(
  forName: NSNotification.Name("com.apple.screenIsUnlocked"),
  object: nil,
  queue: .main
) { _ in
  handleUnlock()
}

print("Listening for lock/unlock events...")
RunLoop.main.run()
