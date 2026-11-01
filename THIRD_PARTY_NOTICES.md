# Third-party notices

SieveSci bundles or adapts material from the following projects. Each remains under its own licence.

| Project | Licence | What is used |
|---|---|---|
| [OpenAI Codex](https://github.com/openai/codex) (commit e790ce27) | Apache-2.0 | Seatbelt sandbox policies (`Resources/sandbox/*.sbpl`) |
| [Reasonix](https://github.com/esengine/DeepSeek-Reasonix) (c9d1664b) | MIT | Provider endpoint catalog; cache-first layout and evidence-receipt design |
| [ZCode](https://github.com/zai-org/ZCode) (aac47556) | Apache-2.0 | Built-in model rules (`Resources/catalog/zcode-builtin.json`); provider page and native search design |
| [Biomni](https://github.com/snap-stanford/biomni) (400c1f36) | Apache-2.0 | Tool and data-lake index (`Resources/catalog/biomni-tools.json`) |
| [ChemCrow](https://github.com/ur-whitelab/chemcrow-public) (e7ebd519) | MIT | Controlled-chemical list (`Resources/catalog/chemcrow-chem-weapons.csv`) |
| [models.dev](https://github.com/sst/models.dev) | MIT | Model capability and price catalog (fetched at runtime) |
| [Pi](https://github.com/earendil-works/pi) | MIT | Per-provider compatibility toggles (design) |
| DeepSeek Harness | MIT | Model listing parser and repeat-tool guard (design) |
| [Hermes Agent](https://github.com/NousResearch/hermes-agent) | MIT | Memory stores and learned-skill format (design) |
| [FutureHouse Robin](https://github.com/Future-House/robin) | Apache-2.0 | Hypothesis tournament and multi-trajectory workflows (design) |
| [K-Dense scientific skills](https://github.com/K-Dense-AI) | MIT | Skill pack format compatibility |
| GPT Researcher, STORM, Agent Laboratory, BioDiscoveryAgent | MIT / Apache-2.0 | Workflow designs, re-expressed as bundled skills |
| [AI Scientist](https://github.com/SakanaAI/AI-Scientist) / [v2](https://github.com/SakanaAI/AI-Scientist-v2) | AI Scientist Source Code License 1.0 (custom) | Workflow ideas (novelty check, figure review), re-expressed as short bundled skills |

Swift package dependencies: MCP Swift SDK (MIT), swift-crypto (Apache-2.0), Yams (MIT), EventSource (MIT),
swift-system (Apache-2.0), swift-markdown-ui (MIT), KeychainAccess (MIT).
