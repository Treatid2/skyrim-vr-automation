# MO2 approval-compatible invocation

Use this contract whenever an MO2, workspace, or profile command needs an
elevated `exec_command` call.

## Direct command shape

Invoke the script as a file under a literal PowerShell executable:

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-entrypoint.ps1> <literal-subcommand> <changing arguments>
```

The executable path, script path, and subcommand are the reusable command
prefix. Session IDs, access IDs, workspace IDs, exact target paths, timeout
values, and labels follow it.

Every controller result reports this command-specific shape under `approval`:

- `reusablePrefix` is the exact argv prefix to offer as `prefix_rule`;
- `reusableApprovalEligible` says whether the operation may be offered for
  conversation-scoped approval;
- `escalationUsuallyRequired` distinguishes read-only calls that normally run
  in the sandbox;
- `oneShotReason` explains why a risky operation must not receive a reusable
  rule.

Use the literal values from this metadata. Do not put the script path or
subcommand in a variable, construct a command string, use `-Command`, prepend
unrelated variable assignments, or append a pipeline or command separator to
an approval request. Parse returned JSON in a separate non-escalated step.

For a session created by `prepare` or `recover-close`, replace the installed
entry point with the exact returned `controllerPath`. That path is stable for
the session. Each session lifecycle subcommand has its own narrow reusable
prefix.

## Reusable versus one-shot operations

The following MO2 lifecycle commands are eligible for a narrow reusable rule:

```text
request-access renew-access release-access prepare open launch status
stop-game close recover-close recover-rootbuilder stop release
```

Read-only `inspect`, `validate`, `access-status`, `status`, and `help` normally
need no escalation, but retain the same literal shape if escalation is required
by the host environment.

Do not propose reusable approval for:

- `recover-access`, because it transfers an abandoned lease;
- workspace `recover-legacy-selection`, because it changes the shared MO2
  selected profile after exact legacy-workspace classification;
- `terminate-game` or `terminate`, because they force process termination;
- workspace `refresh-fixture`, `complete-output`, `retire`, or deprecated
  `release`, because they
  replace shared fixture metadata, restore exact snapshotted Overwrite trees,
  or recursively remove exact owned workspace paths;
- any profile-control mutation, because it overwrites `modlist.txt` under its
  exact backup transaction.

Workspace `prepare-source`, `create`, `resume`, `register-mod`, and
`ensure-mod-wins` are eligible only through the exact workspace entry point and
literal subcommand. Their access and ownership proofs remain mandatory.
`prepare-source` is a non-mutating compatibility inspection. Profile `inspect`
is read-only; all other profile commands remain one-shot.

## Approval request construction

For an eligible operation, pass the reported `reusablePrefix` unchanged as the
approval request's `prefix_rule` and put changing arguments after that prefix
in the command. Keep the justification specific to the operation being
authorized. Do not ask for a bare PowerShell, script-wide, or plugin-wide rule.

For a one-shot operation, omit `prefix_rule`, batch only inseparable checks and
the exact action, and explain why the approval cannot safely be reused.
