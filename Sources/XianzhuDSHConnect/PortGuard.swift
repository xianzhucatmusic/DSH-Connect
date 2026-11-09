//
//  PortGuard.swift — 启动前清理占用端口的残留 llama-server。
//
//  背景：App 被强杀或异常退出时，它启动的 llama-server 会成为孤儿进程
//  （PPID 变成 1）继续占着端口。下次点「启动服务」就会因为绑不上端口而失败，
//  界面上只看到「已退出 (code 1)」，很难看出原因。
//
//  策略：
//    · 只处理**我们自己的** llama-server（可执行文件路径在本 App 包内，
//      或在 Application Support 的 llama 目录下）
//    · 别人跑的进程（别的 App、系统服务）一律不碰
//    · 先 SIGTERM，给它时间自己退；超时才 SIGKILL
//

import Foundation

enum PortGuard {

    /// 一次清理的结果，用于反馈给用户。
    struct CleanupResult {
        var swept: [Int32] = []        // 被清理的 PID
        var foreign: [String] = []     // 端口被别的程序占用（没动它）
        var ready: Bool = true         // 清理后端口是否可用
    }

    /// 判断一个可执行路径是不是本 App 的 llama-server。
    @MainActor
    static func isOurServer(executable rawPath: String) -> Bool {
        // macOS 对被替换过的二进制会在路径后加 " (deleted)"，先去掉
        let path = rawPath.replacingOccurrences(of: " (deleted)", with: "")
        let ours = Paths.serverBin.path                      // 当前包内的 llama-server
        if path == ours { return true }
        // App 更新后包路径可能变过，凡是 "Xianzhu DSH Connect.app" 里的 llama-server 都算自己的
        if path.contains("Xianzhu DSH Connect.app"), path.hasSuffix("/llama-server") {
            return true
        }
        // 也认 Application Support 下的那一份（非打包运行时用的）
        let support = Paths.support.appendingPathComponent("llama/llama-server").path
        return path == support
    }

    /// 列出监听指定端口的进程 (pid, 可执行路径)。
    static func listeners(onPort port: Int) -> [(pid: Int32, path: String)] {
        let lsof = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: lsof) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsof)
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "pc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            PortGuardDiagnostics.log("lsof 启动失败: \(error.localizedDescription)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        PortGuardDiagnostics.log("lsof 退出码=\(process.terminationStatus) 输出字节=\(data.count)")

        guard let text = String(data: data, encoding: .utf8) else { return [] }

        // -F pc 输出形如：
        //   p88618
        //   c/Applications/.../llama-server
        var results: [(Int32, String)] = []
        var currentPID: Int32?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("p") {
                currentPID = Int32(line.dropFirst())
            } else if line.hasPrefix("c"), let pid = currentPID {
                // 字段 c 是命令名；完整路径需要再查一次 ps
                results.append((pid, String(line.dropFirst())))
            }
        }
        // 用 ps 补全每个 PID 的完整路径
        return results.map { (pid, _) in
            (pid, executablePath(of: pid) ?? "")
        }
    }

    /// 查询一个 PID 的完整可执行路径。
    ///
    /// 必须用 `comm=`（只输出可执行文件路径）而不是 `command=`：
    /// command 含命令行参数，按空格切分会把带空格的应用名切断
    /// （例如 "Xianzhu DSH Connect.app" 会被截成 "Xianzhu"）。
    static func executablePath(of pid: Int32) -> String? {
        let ps = "/bin/ps"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ps)
        process.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            PortGuardDiagnostics.log("ps 启动失败: \(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        PortGuardDiagnostics.log("ps pid=\(pid) 输出=\(text)")
        return text.isEmpty ? nil : text
    }

    /// 清理占用端口、且属于本 App 的 llama-server。
    ///
    /// - Parameter port: 要检查的端口。
    /// - Parameter keepPID: 正在由本进程管理的子进程 PID，不要误杀。
    @MainActor
    static func sweep(port: Int, keepPID: Int32? = nil) -> CleanupResult {
        var result = CleanupResult()
        let occupants = listeners(onPort: port)
        PortGuardDiagnostics.log("sweep(port: \(port)) → \(occupants.count) 个监听者: \(occupants.map { "\($0.pid):\($0.path)" }.joined(separator: ", "))")
        if occupants.isEmpty {
            result.ready = true
            return result
        }

        for occupant in occupants {
            if let keepPID, occupant.pid == keepPID { continue }

            let path = occupant.path.isEmpty
                ? (executablePath(of: occupant.pid) ?? "")
                : occupant.path

            // 诊断：记录每次判定用到的路径，方便定位"清不掉"的问题
            PortGuardDiagnostics.log("pid=\(occupant.pid) lsofPath=\(occupant.path) psPath=\(path) ours=\(isOurServer(executable: path)) expected=\(Paths.serverBin.path)")

            guard isOurServer(executable: path) else {
                // 别人的进程：记下来，但绝不动手
                result.foreign.append("PID \(occupant.pid) — \(path.isEmpty ? "未知程序" : path)")
                continue
            }

            // 先温和地请它退出
            kill(occupant.pid, SIGTERM)
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                if kill(occupant.pid, 0) != 0 { break }     // 已退出
                usleep(150_000)
            }
            // 还赖着就强杀
            if kill(occupant.pid, 0) == 0 {
                kill(occupant.pid, SIGKILL)
                usleep(300_000)
            }
            result.swept.append(occupant.pid)
        }

        // 复核端口是否真的空出来了
        let remaining = listeners(onPort: port)
        result.ready = remaining.isEmpty || remaining.allSatisfy { occupant in
            // 剩下的都是别人的进程，我们也无能为力
            !isOurServer(executable: occupant.path)
        }
        return result
    }

    /// 端口当前是否可绑定（快速探测）。
    static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                bind(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}


/// 诊断日志：写入 Application Support 下的 portguard.log，便于排查清理失败。
enum PortGuardDiagnostics {
    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        let dir = Paths.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("portguard.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
