import Foundation

// MARK: - Configuration

/// Paths injected by Nix at build time
let adapterScript = "@ADAPTER_BIN@"
let frameworkPath = "@FRAMEWORK_PATH@"

/// If the screen has been locked for longer than this, reset session uptime on unlock
let sessionResetThreshold: TimeInterval = 1800  // 30 minutes

let stateDir = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent(".local/state/starship-prompt")
let mediaFile = stateDir.appendingPathComponent("media.json")
let lockFile = stateDir.appendingPathComponent("lock")
let sessionStartFile = stateDir.appendingPathComponent("start")

// MARK: - File Utilities

func currentTimestamp() -> Int {
  Int(Date().timeIntervalSince1970)
}

func writeTimestamp(to file: URL) {
  try? String(currentTimestamp()).write(to: file, atomically: true, encoding: .utf8)
}

func readTimestamp(from file: URL) -> TimeInterval? {
  guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
  return TimeInterval(content.trimmingCharacters(in: .whitespacesAndNewlines))
}

func ensureStateDir() {
  try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
}

// MARK: - Session Tracking

/// Records when the screen was locked
func handleScreenLock() {
  writeTimestamp(to: lockFile)
  print("[Session] Screen locked")
}

/// On unlock, reset session start time if locked for too long
func handleScreenUnlock() {
  defer {
    try? FileManager.default.removeItem(at: lockFile)
    print("[Session] Screen unlocked")
  }

  guard let lockTime = readTimestamp(from: lockFile) else { return }
  let lockDuration = Date().timeIntervalSince1970 - lockTime

  if lockDuration > sessionResetThreshold {
    writeTimestamp(to: sessionStartFile)
    print("[Session] Reset session start (locked for \(Int(lockDuration))s)")
  }
}

func registerSessionObservers() {
  let dnc = DistributedNotificationCenter.default()

  dnc.addObserver(
    forName: NSNotification.Name("com.apple.screenIsLocked"),
    object: nil,
    queue: .main
  ) { _ in handleScreenLock() }

  dnc.addObserver(
    forName: NSNotification.Name("com.apple.screenIsUnlocked"),
    object: nil,
    queue: .main
  ) { _ in handleScreenUnlock() }
}

// MARK: - Media Tracking

struct MediaState: Encodable {
  let title: String
  let artist: String
  let isPlaying: Bool
  let timestamp: Int
}

/// Buffer for accumulating partial output from the media adapter
var mediaOutputBuffer = Data()

func startMediaListener() {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
  // --no-diff ensures we get full title/artist even when only playback state changes
  process.arguments = [adapterScript, frameworkPath, "stream", "--no-diff"]

  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr

  do {
    try process.run()
    print("[Media] Adapter started")
  } catch {
    print("[Media] Failed to start adapter: \(error)")
    return
  }

  stdout.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    mediaOutputBuffer.append(data)
    processMediaOutput()
  }

  stderr.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
      print("[Media] Adapter error: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
  }

  process.terminationHandler = { _ in
    print("[Media] Adapter exited, restarting in 5s...")
    stdout.fileHandleForReading.readabilityHandler = nil
    stderr.fileHandleForReading.readabilityHandler = nil
    mediaOutputBuffer.removeAll()
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { startMediaListener() }
  }
}

func processMediaOutput() {
  let newline = Data("\n".utf8)

  while let range = mediaOutputBuffer.range(of: newline) {
    let lineData = mediaOutputBuffer.subdata(in: 0..<range.lowerBound)
    mediaOutputBuffer.removeSubrange(0..<range.upperBound)

    guard let line = String(data: lineData, encoding: .utf8) else { continue }
    handleMediaUpdate(line)
  }
}

func handleMediaUpdate(_ jsonString: String) {
  guard let data = jsonString.data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return }

  // The adapter may wrap the payload, or send it directly
  let info = (root["payload"] as? [String: Any]) ?? root

  let media = MediaState(
    title: (info["title"] as? String) ?? "",
    artist: (info["artist"] as? String) ?? "",
    isPlaying: (info["playing"] as? Bool) ?? false,
    timestamp: currentTimestamp()
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  try? encoder.encode(media).write(to: mediaFile)
}

// MARK: - Main

print("[Daemon] Starting...")
ensureStateDir()

if !FileManager.default.fileExists(atPath: sessionStartFile.path) {
  writeTimestamp(to: sessionStartFile)
}

registerSessionObservers()
DispatchQueue.global().async { startMediaListener() }

print("[Daemon] Listening for events...")
RunLoop.main.run()
