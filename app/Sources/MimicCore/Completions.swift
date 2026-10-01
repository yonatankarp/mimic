import Foundation

/// `mimic completions zsh|bash|fish` (#131): a script that completes commands, options and their
/// values, and mini and project names, which it asks `mimic _names` for as you type. Made from
/// the usage text (`Usage.text`), so a new command or option there is completed without more work.
public enum Completions {
    public enum Shell: String, CaseIterable, Sendable { case zsh, bash, fish }

    /// What a word takes: nothing (a flag), any text, a mini's or project's name, a file, or one of a few words.
    public enum Value: Equatable, Sendable {
        case flag, text, mini, project, file
        case choice([String])
    }

    public struct Option: Equatable, Sendable {
        /// With its dashes: "--height".
        public var name: String
        public var value: Value
    }

    /// A command ("resize") or a command and its subcommand ("queue move").
    public struct Command: Equatable, Sendable {
        public var name: String
        /// The word after it, when it takes one.
        public var argument: Value?
        /// Its subcommands, for a command that has them ("queue": remove, move, pause, resume).
        public var subcommands: [String] = []
        public var options: [Option] = []
        /// It takes the size options, the usage's `[options]`.
        var sizes = false
    }

    /// The commands as the usage text lists them, in its order, and the options for the
    /// first word (`--version`, `--help`).
    public static func parse(_ text: String = Usage.text) -> (commands: [Command], top: [String]) {
        var commands: [Command] = [], top: [String] = [], shared: [Option] = [], notes: [(command: String, explains: Bool, options: [Option])] = []
        func index(_ name: String) -> Int {
            if let i = commands.firstIndex(where: { $0.name == name }) { return i }
            commands.append(Command(name: name))
            return commands.count - 1
        }
        func add(_ o: Option, to i: Int) {
            if !commands[i].options.contains(where: { $0.name == o.name }) { commands[i].options.append(o) }
        }
        for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("mimic ") {
                // Its usage, before the explanation two spaces on.
                let usage = line.range(of: "  ").map { String(line[..<$0.lowerBound]) } ?? line
                let t = words(usage)
                guard t.count > 1 else { continue }
                if t[1].hasPrefix("-") { top.append(t[1]); continue }
                let cmd = t[1]
                var i = 2, subs: [String] = [], choice: [String]?
                while i < t.count, !["<", "\"", "[", "-"].contains(where: t[i].hasPrefix) {
                    if t[i] != "|" {
                        if t[i].contains("|") { choice = t[i].split(separator: "|").map(String.init) } else { subs.append(t[i]) }
                    }
                    i += 1
                }
                let c = index(cmd)
                if let choice { commands[c].argument = .choice(choice) }
                for s in subs where !commands[c].subcommands.contains(s) { commands[c].subcommands.append(s) }
                let k = subs.count == 1 ? index("\(cmd) \(subs[0])") : c
                // A new mini's or project's name is new: nothing to complete.
                if commands[k].argument == nil, i < t.count, cmd != "make", subs != ["create"], let v = value(t[i]), v != .text { commands[k].argument = v }
                for (j, raw) in t.enumerated() where j >= i {
                    if raw == "[options]" { commands[k].sizes = true }
                    let tok = bare(raw)
                    if tok.hasPrefix("--") { add(Option(name: tok, value: j + 1 < t.count ? value(t[j + 1]) ?? .flag : .flag), to: k) }
                }
            } else {
                // A note: "make … --project …" and "make-another --new-shape: …" are that
                // command's; "--wait: …" explains an option; anything else ("options: …") is for
                // every command with [options].
                let t = words(line)
                guard let lead = t.first.map(bare) else { continue }
                let command = t.firstIndex(of: "…").flatMap { $0 > 0 ? t[$0 - 1] : nil } ?? lead
                var options: [Option] = []
                for (j, raw) in t.enumerated() where bare(raw).hasPrefix("--") {
                    let explained = raw.hasSuffix(":")
                    options.append(Option(name: bare(raw), value: explained || j + 1 == t.count ? .flag : value(t[j + 1]) ?? .flag))
                }
                notes.append((command, lead.hasPrefix("--") && t[0].hasSuffix(":"), options))
            }
        }
        let inCommands = Set(commands.flatMap { $0.options.map(\.name) })
        for note in notes {
            if let i = commands.firstIndex(where: { $0.name == note.command }) {
                note.options.forEach { add($0, to: i) }
            } else {
                // One explained that a command already lists (--json, --improve) stays that command's.
                shared += note.options.filter { o in !(note.explains && inCommands.contains(o.name)) && !shared.contains { $0.name == o.name } }
            }
        }
        for i in commands.indices where commands[i].sizes { shared.forEach { add($0, to: i) } }
        return (commands, top)
    }

    static func words(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

    /// An option as written, without the brackets and colon around it: "[--json]" is "--json".
    static func bare(_ raw: String) -> String { raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]:")) }

    /// What the word after an option or command says it takes; nil when it's another option.
    static func value(_ raw: String) -> Value? {
        let w = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]:,"))
        if w.isEmpty || ["-", "[", "|", "(", "…"].contains(where: raw.hasPrefix) { return nil }
        if w == "\"<project>\"" { return .project }
        if w == "<name>" || w.hasPrefix("<name>") { return .mini }
        if w.hasPrefix("<file") || w == "<picture>" { return .file }
        if w == "ID" { return .choice(EngineDownload.catalogue.map(\.id)) }  // --model
        if w.contains("|") { return .choice(w.split(separator: "|").map(String.init).filter { !$0.hasPrefix("<") }) }
        return .text
    }

    // MARK: The scripts

    public static func script(_ shell: Shell) -> String {
        let (commands, top) = parse()
        let first = commands.map { $0.name }.filter { !$0.contains(" ") } + top
        switch shell {
        case .bash: return bash(commands, first)
        case .zsh: return zsh(commands, first)
        case .fish: return fish(commands, first)
        }
    }

    private static func quoted(_ name: String) -> String { name.contains(" ") ? "\"\(name)\"" : name }

    private static func bash(_ commands: [Command], _ first: [String]) -> String {
        func words(_ v: Value, _ cur: String = "$cur") -> String {
            switch v {
            case .flag, .text: "return"
            case .mini: "_mimic_names minis \"\(cur)\""
            case .project: "_mimic_names projects \"\(cur)\""
            case .file: "COMPREPLY=($(compgen -f -- \"\(cur)\"))"
            case .choice(let c): "COMPREPLY=($(compgen -W \"\(c.joined(separator: " "))\" -- \"\(cur)\"))"
            }
        }
        var out = """
        # mimic completions for bash. Add to ~/.bash_profile: eval "$(mimic completions bash)"
        # A name with a space ("My Town") goes in as My\\ Town.
        _mimic_names() {
            local IFS=$'\\n' i; COMPREPLY=($(compgen -W "$(mimic _names "$1" 2>/dev/null)" -- "$2"))
            for i in "${!COMPREPLY[@]}"; do COMPREPLY[i]=$(printf %q "${COMPREPLY[i]}"); done
        }
        _mimic() {
            local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]} key=${COMP_WORDS[1]} at=2 opts=""
            COMPREPLY=()
            if [ "$COMP_CWORD" -eq 1 ]; then COMPREPLY=($(compgen -W "\(first.joined(separator: " "))" -- "$cur")); return; fi
            case "$key" in

        """
        for c in commands where !c.subcommands.isEmpty {
            out += "        \(c.name)) if [ \"$COMP_CWORD\" -eq 2 ] && [[ \"$cur\" != -* ]]; then COMPREPLY=($(compgen -W \"\(c.subcommands.joined(separator: " "))\" -- \"$cur\")); return; fi\n"
            out += "            case \"${COMP_WORDS[2]}\" in \(c.subcommands.joined(separator: "|"))) key=\"$key ${COMP_WORDS[2]}\"; at=3;; esac;;\n"
        }
        out += "    esac\n    case \"$key\" in\n"
        for c in commands {
            out += "        \(quoted(c.name)))\n"
            let valued = c.options.filter { $0.value != .flag }
            if !valued.isEmpty {
                out += "            case \"$prev\" in\n"
                for o in valued { out += "                \(o.name)) \(o.value == .text ? "" : words(o.value) + "; ")return;;\n" }
                out += "            esac\n"
            }
            out += "            opts=\"\(c.options.map(\.name).joined(separator: " "))\"\n"
            if let a = c.argument, a != .flag, a != .text {
                out += "            if [[ \"$cur\" != -* ]] && [ \"$COMP_CWORD\" -eq \"$at\" ]; then \(words(a)); return; fi\n"
            }
            out += "            ;;\n"
        }
        out += """
            esac
            [[ "$cur" == -* ]] && COMPREPLY=($(compgen -W "$opts" -- "$cur"))
        }
        complete -F _mimic mimic

        """
        return out
    }

    private static func zsh(_ commands: [Command], _ first: [String]) -> String {
        func words(_ v: Value) -> String {
            switch v {
            case .flag, .text: "return"
            case .mini: "_mimic_names minis"
            case .project: "_mimic_names projects"
            case .file: "_files"
            case .choice(let c): "compadd -- \(c.joined(separator: " "))"
            }
        }
        var out = """
        #compdef mimic
        # mimic completions for zsh. Add to ~/.zshrc, after compinit: source <(mimic completions zsh)
        _mimic_names() { local -a n; n=("${(@f)$(mimic _names $1 2>/dev/null)}"); compadd -a n }
        _mimic() {
            local key=${words[2]} at=3 prev=${words[CURRENT-1]} cur=${words[CURRENT]} opts=""
            if (( CURRENT == 2 )); then compadd -- \(first.joined(separator: " ")); return; fi
            case $key in

        """
        for c in commands where !c.subcommands.isEmpty {
            out += "        \(c.name)) if (( CURRENT == 3 )) && [[ $cur != -* ]]; then compadd -- \(c.subcommands.joined(separator: " ")); return; fi\n"
            out += "            case ${words[3]} in \(c.subcommands.joined(separator: "|"))) key=\"$key ${words[3]}\"; at=4;; esac;;\n"
        }
        out += "    esac\n    case $key in\n"
        for c in commands {
            out += "        \(quoted(c.name)))\n"
            let valued = c.options.filter { $0.value != .flag }
            if !valued.isEmpty {
                out += "            case $prev in\n"
                for o in valued { out += "                \(o.name)) \(o.value == .text ? "" : words(o.value) + "; ")return;;\n" }
                out += "            esac\n"
            }
            out += "            opts=\"\(c.options.map(\.name).joined(separator: " "))\"\n"
            if let a = c.argument, a != .flag, a != .text {
                out += "            if [[ $cur != -* ]] && (( CURRENT == at )); then \(words(a)); return; fi\n"
            }
            out += "            ;;\n"
        }
        out += """
            esac
            [[ $cur == -* ]] && compadd -- ${=opts}
        }
        if (( $+functions[compdef] )); then compdef _mimic mimic; fi

        """
        return out
    }

    private static func fish(_ commands: [Command], _ first: [String]) -> String {
        var out = """
        # mimic completions for fish. Save them: mimic completions fish > ~/.config/fish/completions/mimic.fish
        function __mimic_names; mimic _names $argv 2>/dev/null; end
        # The words after mimic start with these.
        function __mimic_is
            set -l w (commandline -opc)
            test (count $w) -gt (count $argv); or return 1
            for i in (seq (count $argv))
                set -l j (math $i + 1)
                test "$w[$j]" = "$argv[$i]"; or return 1
            end
        end
        # They're exactly these, so the next word is the command's own.
        function __mimic_next
            __mimic_is $argv; and test (count (commandline -opc)) -eq (math (count $argv) + 1)
        end
        complete -c mimic -f
        complete -c mimic -n "test (count (commandline -opc)) -eq 1" -a "\(first.filter { !$0.hasPrefix("-") }.joined(separator: " "))"

        """
        for t in first where t.hasPrefix("--") {
            out += "complete -c mimic -n \"test (count (commandline -opc)) -eq 1\" -l \(t.dropFirst(2))\n"
        }
        func values(_ v: Value) -> String {
            switch v {
            case .flag: ""
            case .text: " -x"
            case .mini: " -x -a \"(__mimic_names minis)\""
            case .project: " -x -a \"(__mimic_names projects)\""
            case .file: " -r -F"
            case .choice(let c): " -x -a \"\(c.joined(separator: " "))\""
            }
        }
        for c in commands {
            let key = c.name
            if !c.subcommands.isEmpty {
                out += "complete -c mimic -n \"__mimic_next \(key)\" -a \"\(c.subcommands.joined(separator: " "))\"\n"
            }
            if let a = c.argument, a != .flag, a != .text {
                let v = values(a)
                out += "complete -c mimic -n \"__mimic_next \(key)\"\(a == .file ? " -F" : v.replacingOccurrences(of: " -x", with: ""))\n"
            }
            for o in c.options {
                out += "complete -c mimic -n \"__mimic_is \(key)\" -l \(o.name.dropFirst(2))\(values(o.value))\n"
            }
        }
        return out
    }
}
