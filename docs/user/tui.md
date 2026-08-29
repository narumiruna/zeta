# Terminal UI

Zeta provides main-screen and alternate-screen renderers.
Both use synchronized output and reset SGR and OSC 8 state on each line.
The main-screen renderer preserves terminal scrollback and performs differential updates.
The alternate-screen renderer owns a fixed viewport and can print the transcript on exit.

The terminal enables raw input, bracketed paste, Kitty keyboard negotiation, and cursor restoration.
The input decoder buffers fragmented CSI, OSC, DCS, APC, mouse, and paste sequences.
A lone Escape uses a longer delay over SSH.
Key-release reports are drained rather than inserted into the editor.

Components include text, truncated text, boxes, containers, input, editor, Markdown, lists, settings, stacks, scroll views, autocomplete, and inline images.
The editor supports multiline input, deletion, undo, redo, large-paste markers, and command completion.
Display width accounts for ANSI controls, CJK, emoji, and combining marks.
Kitty and iTerm image protocols are selected from terminal capabilities and explicit overrides.
Unsupported image terminals render a textual placeholder.

Escape aborts the active agent operation.
Ctrl-C exits interactive mode.
Slash commands include help, new, session, thinking, compact, abort, and quit.
Prefix a command with `!` to execute it directly in the session working directory.
