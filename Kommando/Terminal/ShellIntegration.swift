//
//  ShellIntegration.swift
//  Kommando
//
//  Auto-injects OSC 133 (FinalTerm) shell-integration marks into Kommando's zsh
//  sessions so the Command Blocks feature works out of the box, without the user
//  installing anything.
//
//  Mechanism: we point the shell at a Kommando-owned `ZDOTDIR` whose startup files
//  first source the user's *real* zsh config (from their original ZDOTDIR / $HOME),
//  then load our integration hooks. This is the same approach VS Code uses, and it
//  only affects shells Kommando launches — turning the feature off launches plain
//  shells again.
//

import Foundation

enum ShellIntegration {
    /// Environment-variable name carrying the user's original ZDOTDIR into our bootstrap.
    static let userZDotDirKey = "KOMMANDO_USER_ZDOTDIR"

    /// Returns the path to Kommando's `ZDOTDIR`, creating/refreshing the bootstrap files,
    /// or nil if it couldn't be written.
    static func zdotDir() -> String? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else {
            return nil
        }
        let dir = support.appendingPathComponent("Kommando/shell-integration", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, contents) in files {
                let url = dir.appendingPathComponent(name)
                let data = Data(contents.utf8)
                // Only rewrite when changed, to avoid churn / racing concurrent shell starts.
                if (try? Data(contentsOf: url)) != data {
                    try data.write(to: url, options: .atomic)
                }
            }
        } catch {
            return nil
        }
        return dir.path
    }

    /// Bootstrap files keyed by filename. Each defers to the user's real startup file
    /// (read from `$USER_ZDOTDIR`) while keeping our ZDOTDIR active so the next file in
    /// zsh's startup sequence is still read from here.
    private static var files: [String: String] {
        [
            ".zshenv": """
            # Kommando shell integration — bootstrap (.zshenv).
            KOMMANDO_ZDOTDIR="$ZDOTDIR"
            USER_ZDOTDIR="${KOMMANDO_USER_ZDOTDIR:-$HOME}"
            ZDOTDIR="$USER_ZDOTDIR"
            [[ -f "$USER_ZDOTDIR/.zshenv" ]] && source "$USER_ZDOTDIR/.zshenv"
            USER_ZDOTDIR="$ZDOTDIR"
            ZDOTDIR="$KOMMANDO_ZDOTDIR"

            """,
            ".zprofile": """
            # Kommando shell integration — bootstrap (.zprofile).
            ZDOTDIR="$USER_ZDOTDIR"
            [[ -f "$USER_ZDOTDIR/.zprofile" ]] && source "$USER_ZDOTDIR/.zprofile"
            USER_ZDOTDIR="$ZDOTDIR"
            ZDOTDIR="$KOMMANDO_ZDOTDIR"

            """,
            ".zshrc": """
            # Kommando shell integration — bootstrap (.zshrc).
            ZDOTDIR="$USER_ZDOTDIR"
            [[ -f "$USER_ZDOTDIR/.zshrc" ]] && source "$USER_ZDOTDIR/.zshrc"
            USER_ZDOTDIR="$ZDOTDIR"
            ZDOTDIR="$KOMMANDO_ZDOTDIR"
            # Load our OSC 133 hooks after the user's full interactive config so they
            # survive prompt frameworks (Powerlevel10k, oh-my-zsh, starship, …).
            [[ -f "$KOMMANDO_ZDOTDIR/kommando-integration.zsh" ]] && source "$KOMMANDO_ZDOTDIR/kommando-integration.zsh"

            """,
            ".zlogin": """
            # Kommando shell integration — bootstrap (.zlogin).
            ZDOTDIR="$USER_ZDOTDIR"
            [[ -f "$USER_ZDOTDIR/.zlogin" ]] && source "$USER_ZDOTDIR/.zlogin"
            USER_ZDOTDIR="$ZDOTDIR"
            ZDOTDIR="$KOMMANDO_ZDOTDIR"

            """,
            "kommando-integration.zsh": integrationScript,
        ]
    }

    /// Emits OSC 133 marks: `A` prompt start and `B` command start are woven into PS1 as
    /// zero-width sequences (so they track the real prompt geometry, which matters for
    /// multi-line prompts like p10k); `C` (output start) and `D;<exit>` are emitted from
    /// preexec/precmd. The preexec/precmd dance strips our marks before each command runs
    /// and re-applies them afterwards, mirroring the well-tested iTerm2 approach so it
    /// coexists with prompt frameworks that rebuild PS1 every prompt.
    private static let integrationScript = """
    # Kommando Command Blocks — OSC 133 shell integration (zsh).
    if [[ -o interactive ]] && [[ "$TERM" != dumb ]] && [[ -z "${KOMMANDO_SI:-}" ]]; then
      KOMMANDO_SI=1

      typeset -g __kommando_raw_ps1=""
      typeset -g __kommando_decorated_ps1=""
      typeset -g __kommando_should_decorate=1

      __kommando_decorate() {
        __kommando_raw_ps1="$PS1"
        __kommando_should_decorate=""
        # %{ %} marks the bytes as zero-width so the prompt's visible layout is unchanged.
        PS1=$'%{\\033]133;A\\007%}'"$PS1"$'%{\\033]133;B\\007%}'
        __kommando_decorated_ps1="$PS1"
      }

      __kommando_preexec() {
        # Restore the undecorated prompt before the command runs, then mark output start.
        [[ -n "$__kommando_raw_ps1" ]] && PS1="$__kommando_raw_ps1"
        __kommando_should_decorate=1
        printf '\\033]133;C\\007'
      }

      __kommando_precmd() {
        local __kommando_status=$?
        printf '\\033]133;D;%s\\007' "$__kommando_status"
        if [[ -z "$__kommando_should_decorate" ]]; then
          # ^C path: preexec didn't run; re-decorate if the prompt changed meanwhile.
          [[ "$PS1" != "$__kommando_decorated_ps1" ]] && __kommando_should_decorate=1
        fi
        [[ -n "$__kommando_should_decorate" ]] && __kommando_decorate
      }

      autoload -Uz add-zsh-hook 2>/dev/null
      if (( $+functions[add-zsh-hook] )); then
        add-zsh-hook precmd __kommando_precmd
        add-zsh-hook preexec __kommando_preexec
      else
        precmd_functions+=(__kommando_precmd)
        preexec_functions+=(__kommando_preexec)
      fi
    fi

    """
}
