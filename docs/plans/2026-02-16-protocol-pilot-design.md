# Protocol-Driven Pilot Mode for codex.sh

## Problem

codex.sh is a one-shot wrapper. We need it to support autonomous, multi-step Codex sessions where the LLM operates in a control loop — reading system state, taking actions, verifying results, and iterating toward an objective.

## Design

Add a `-p FILE` flag to codex.sh. When provided, the file is read and prepended to the prompt as an operating protocol. The objective comes via the existing prompt mechanisms (positional args, `-f`, or stdin).

### Interface

```bash
./codex.sh -p PROTOCOL.md "Run 3 Twin cycles, report findings"
./codex.sh -p PROTOCOL.md -f objective.txt
echo "Diagnose Twin 3" | ./codex.sh -p PROTOCOL.md
```

Without `-p`, codex.sh behaves exactly as today.

### Prompt Assembly

When `-p` is provided, the final prompt becomes:

```
You are operating under the following protocol.
Read it completely before taking any action.

--- BEGIN PROTOCOL ---
<contents of protocol file>
--- END PROTOCOL ---

Objective: <prompt from args / -f / stdin>

Execute according to the protocol. Stop and report if you encounter
an unrecoverable error or if the objective is complete.
```

### Validation

- `-p` given but file doesn't exist: error, exit 1.
- `-p` given but no objective provided: error, exit 2.
- `-p` file is empty: error, exit 1.

### Changes to codex.sh

- Add `p:` to the `getopts` string.
- New variable `protocol_file`.
- After prompt resolution, if `protocol_file` is set, read it and wrap the assembled prompt.
- Update usage text.

### What This Enables

Protocol files (e.g., `DISCORDIA.md` in a downstream project) define the handoff: command interface, operating policy, safety guardrails, cycle pattern, observability requirements. The objective specifies bounding and intent. Codex reads the protocol, executes the objective autonomously within one session, and exits when done or on error.

### Scope

~20 lines of changes to codex.sh. No new files, scripts, or conventions in DiscordiaOS. Protocol files live in downstream projects (e.g., PowerCon5).
