# Mistype

Mistype is an experiment in low-interference text capture: two split touch surfaces (initially simulated in software) let a user type from muscle memory without stopping to aim at precise keys or choose Chinese candidates. A phonetic trace is captured first, then reconstructed into Chinese, English, or mixed text after a pause or explicit commit.

The first target is Bopomofo (Zhuyin), with English mixing and a local decoder. The project begins as a software prototype so that interaction, decoding quality, and latency can be measured before designing hardware.

## Documents

- [Project outline](docs/project-outline.md): product intent, milestones, experiments, and success criteria.
- [Technical architecture](docs/architecture.md): layers, event contracts, decoding pipeline, and deployment choices.
- [Development guide](AGENTS.md): working loop, privacy rules, and definition of done.

The design takes inspiration from [Qingjian](https://github.com/qingjian-team/qingjian), especially its platform-independent core and delayed whole-phrase reconstruction. Mistype is a separate experiment; compatibility with Qingjian is a milestone, not a promise.
