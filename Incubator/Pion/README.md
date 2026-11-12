# Pion

Pion is a cyber defence tool for one operator on a Mac: a team of agents investigates incidents with
you, and you stay in charge of anything that changes a system. It runs agents the way Noodle does,
on the same harnesses, and keeps its own agents, conversations and sign-ins apart from Noodle's.

Pion is incubating: it has no release yet. Build it with `scripts/build.sh` in this folder, which
puts Pion Dev in the repository's `.build` folder.

## Investigations, groups and agents

The sidebar lists your Investigations, most severe first, with closed ones folded under Closed; then
your groups; then your agents. Choose File > New Investigation (⌘N), New Group (⌥⌘N) or New Agent
(⇧⌘N), or the plus beside a section's title.

An Investigation is a conversation with its team, with an objective, a scope, a status and a case
record. One agent leads it; you own it. The toolbar sets its status and severity, adds or removes
agents, and shows the case record. Investigation > Close Investigation… closes it as a false
positive, resolved or handed off, with a note.

A group is a standing team you talk to outside any Investigation. Each agent also has a conversation
of its own with you.

## Writing

Write in the field at the bottom; Return sends. Mention an agent with @. The plus attaches files,
and the microphone (⌘⇧D) turns what you say into text in the field, to read over before sending.

## The case record

The inspector beside an Investigation (⌥⌘I) shows what its agents record as they work: actions
waiting for your approval first, then the scope, findings with the evidence they cite, actions and
what became of them, evidence with the exact query that produced it, and the entities involved.
Audit Log lists every change to the Investigation and who made it, and is only ever added to.

Agents never change a system themselves: they propose an action, and Pion's policy allows it, sends
it to you, or refuses it. A target outside the scope, or a protected asset, is always refused.
Pion does not carry actions out yet; mark an approved action done once it has been.

## Settings

Harness signs in to the harnesses agents run on, Agents changes their models and archives them, and
Tools connects them to services over MCP.

## Scenarios

`scripts/scenario.sh` opens Pion in a scenario from `Scenarios/`: a scripted team and
Investigations in a separate copy of Pion Dev with no network and no access to your data. Without a
name it opens the picker. With a name the scenario plays; Return in the terminal, or Scenarios > Next
Step, goes on when it waits. `--shots` saves each captured step to the scenario's `shots` folder.

## License

Source available under the PolyForm Noncommercial License 1.0.0: free to read, use and
change for noncommercial purposes. See LICENSE.md. This is not an open-source license.
