import Foundation

/// The pure parts of an SSH tunnel (S-047): the `ssh` arguments, the askpass
/// script, and what `ssh`'s words mean. `TunnelPool` runs the process.
public enum SSHTunnel {
    /// An SSH login with its blanks filled in (`ConnectionDetails.ssh`).
    public struct Login: Sendable, Equatable, Hashable {
        public var host: String
        public var port: Int
        public var user: String
        /// A private key file, tilde expanded; nil uses the agent and ~/.ssh.
        public var keyFile: String?
        /// The SSH password, or the key's passphrase. Not part of the pool's key.
        public var secret: String?

        public init(host: String, port: Int = 22, user: String, keyFile: String? = nil, secret: String? = nil) {
            self.host = host
            self.port = port
            self.user = user
            self.keyFile = keyFile
            self.secret = secret
        }

        public var mode: Mode {
            if keyFile != nil { return .key }
            return secret == nil ? .agent : .password
        }

        /// "deploy@staging", or "deploy@staging:2222".
        public var place: String { port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)" }
    }

    /// How `ssh` logs in.
    public enum Mode: Sendable, Equatable {
        /// A key file, with its passphrase if it has one.
        case key
        /// A password, asked by the server.
        case password
        /// The SSH agent and the default keys in ~/.ssh.
        case agent
    }

    /// Test seams: a separate known_hosts and no user config.
    public struct Files: Sendable, Equatable {
        public var knownHosts: String?
        public var config: String?
        public init(knownHosts: String? = nil, config: String? = nil) {
            self.knownHosts = knownHosts
            self.config = config
        }
    }

    /// The arguments for `ssh` that forward `socketPath` on this Mac to
    /// `targetHost:targetPort` as the SSH host sees it, with no shell.
    public static func arguments(_ login: Login, targetHost: String, targetPort: Int, socketPath: String,
                                 files: Files = Files()) -> [String] {
        var args = ["-N",
                    "-o", "ExitOnForwardFailure=yes",
                    // Unknown keys go to askpass, which answers only for a fingerprint people trusted.
                    "-o", "StrictHostKeyChecking=ask",
                    "-o", "ConnectTimeout=10",
                    "-o", "ServerAliveInterval=30",
                    "-o", "ServerAliveCountMax=3",
                    "-o", "NumberOfPasswordPrompts=1",
                    "-o", "StreamLocalBindUnlink=yes",
                    "-o", "ControlMaster=no",
                    "-o", "ControlPath=none"]
        if let config = files.config { args += ["-F", config] }
        if let knownHosts = files.knownHosts { args += ["-o", "UserKnownHostsFile=\(knownHosts)"] }
        switch login.mode {
        case .key:
            args += ["-i", login.keyFile ?? "", "-o", "IdentitiesOnly=yes"]
        case .password:
            args += ["-o", "PubkeyAuthentication=no",
                     "-o", "PreferredAuthentications=keyboard-interactive,password"]
        case .agent:
            break
        }
        let target = targetHost.contains(":") ? "[\(targetHost)]" : targetHost
        args += ["-p", String(login.port), "-l", login.user,
                 "-L", "\(socketPath):\(target):\(targetPort)",
                 // Nothing after "--" is an option, so a host can never pass one.
                 "--", login.host]
        return args
    }

    /// The askpass script `ssh` runs for each question. It records the question,
    /// answers a host key question only for a fingerprint in `trusted`, and any
    /// other with the secret file, if there is one.
    public static let askpassScript = """
        #!/bin/sh
        f="$QUARRY_SSH_FOLDER"
        printf '%s\\0' "$1" >> "$f/prompts"
        case "$1" in
        *"continue connecting"*)
          [ -f "$f/trusted" ] && printf '%s' "$1" | grep -qF -f "$f/trusted" && echo yes && exit 0
          exit 1 ;;
        esac
        [ -f "$f/secret" ] && cat "$f/secret" && exit 0
        exit 1

        """

    /// A question `ssh` asked that Quarry needs people to answer.
    public enum Prompt: Sendable, Equatable {
        /// The SSH password.
        case password
        /// The passphrase of this key file.
        case passphrase(String)
        /// An SSH host key not in known_hosts.
        case unknownHost(HostKey)
    }

    /// An SSH host's key, as `ssh` described it.
    public struct HostKey: Sendable, Equatable {
        /// "[127.0.0.1]:3398", or "staging".
        public var host: String
        /// "ED25519".
        public var type: String
        /// "SHA256:…".
        public var fingerprint: String

        public init(host: String, type: String, fingerprint: String) {
            self.host = host
            self.type = type
            self.fingerprint = fingerprint
        }
    }

    /// What one askpass question was.
    public static func prompt(_ text: String) -> Prompt? {
        if text.contains("continue connecting") {
            guard let fingerprint = firstMatch(#"(SHA256:[A-Za-z0-9+/=]+)"#, in: text) else { return nil }
            let host = firstMatch(#"authenticity of host '([^' ]+)"#, in: text) ?? ""
            let type = firstMatch(#"([A-Za-z0-9-]+) key fingerprint is"#, in: text) ?? ""
            return .unknownHost(HostKey(host: host, type: type, fingerprint: fingerprint))
        }
        if text.localizedCaseInsensitiveContains("passphrase") {
            return .passphrase(firstMatch(#"for key '([^']+)'"#, in: text) ?? "")
        }
        if text.localizedCaseInsensitiveContains("password") || text.localizedCaseInsensitiveContains("verification code") {
            return .password
        }
        return nil
    }

    /// Why `ssh` stopped before the tunnel was up: a question people answer and
    /// then try again, or an error. `prompts` are the askpass questions it asked.
    public static func failure(stderr: String, prompts: [String], login: Login, trusted: String?) -> any Error {
        let asked = prompts.compactMap(prompt)
        for question in asked {
            if case .unknownHost(let key) = question, key.fingerprint != trusted {
                return SSHQuestion(prompt: question, login: login)
            }
        }
        let place = "\(login.host):\(login.port)"
        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || stderr.contains("has changed and you have requested strict") {
            return DatabaseError(message: "The key for \(login.host) has changed since you trusted it.",
                                 suggestion: "If the SSH host was set up again, remove its old key from ~/.ssh/known_hosts and connect again.")
        }
        if stderr.contains("Could not resolve hostname") {
            return DatabaseError(message: "Could not find the SSH host \"\(login.host)\".", suggestion: "Check the SSH host name.")
        }
        if ["Connection refused", "timed out", "No route to host", "Network is unreachable"]
            .contains(where: stderr.contains) {
            return DatabaseError(message: "Could not reach the SSH host \(place).",
                                 suggestion: "Check that the SSH host is on and the SSH port is right.")
        }
        if let key = login.keyFile {
            if stderr.contains("UNPROTECTED PRIVATE KEY FILE") || stderr.contains("bad permissions") {
                return DatabaseError(message: "Other users can read the SSH key at \(key), so ssh will not use it.",
                                     suggestion: "Make it private: chmod 600 \(key)")
            }
            if stderr.contains("No such file") || stderr.contains("not accessible") {
                return DatabaseError(message: "There is no SSH key at \(key).", suggestion: "Choose the key file again.")
            }
        }
        if login.secret == nil {
            for question in asked {
                switch question {
                case .password, .passphrase: return SSHQuestion(prompt: question, login: login)
                case .unknownHost: continue
                }
            }
        }
        if stderr.contains("Permission denied") || stderr.contains("Too many authentication failures")
            || stderr.contains("incorrect passphrase") {
            let what = asked.contains(where: { if case .passphrase = $0 { true } else { false } })
                ? "Check the SSH user and the key's passphrase." : "Check the SSH user, password and key."
            return DatabaseError(message: "The SSH host did not accept the login for \(login.user).", suggestion: what)
        }
        if stderr.contains("Host key verification failed") {
            return DatabaseError(message: "Quarry could not check the key of \(login.host).",
                                 suggestion: "Connect to it once with ssh in Terminal, then try again.")
        }
        let last = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("setsockopt") && !$0.hasPrefix("Warning:") }
        return DatabaseError(message: "The SSH connection to \(place) failed" + (last.map { ": \($0)" } ?? "."),
                             suggestion: nil)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// `ssh` asked something people must answer before Quarry tries again (S-047):
/// whether to trust a host key, or a password or passphrase.
public struct SSHQuestion: Error, Sendable, Equatable, LocalizedError {
    public var prompt: SSHTunnel.Prompt
    public var login: SSHTunnel.Login

    public init(prompt: SSHTunnel.Prompt, login: SSHTunnel.Login) {
        self.prompt = prompt
        self.login = login
    }

    public var errorDescription: String? {
        switch prompt {
        case .unknownHost(let key): "Quarry has not seen the key of \(key.host) before."
        case .password: "Enter the SSH password for \(login.place)."
        case .passphrase(let key): "Enter the passphrase for \((key as NSString).lastPathComponent)."
        }
    }
}
