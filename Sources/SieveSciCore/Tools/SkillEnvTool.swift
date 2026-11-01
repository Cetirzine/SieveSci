import Foundation

/// Shows and sets up a skill's own Python environment. `status` is free; `setup` downloads Python
/// packages (and with uv possibly a Python build), so it is approved like any external call — for
/// subagents too, since it runs outside their sandbox.
struct SkillEnvTool: Tool {
    let name = "skill_env"
    let description = """
    A skill's own Python environment. action "status": what the skill needs (Python version, packages, \
    GPU, API keys, binaries, things to install by hand) and whether its environment is ready. action \
    "setup": create the environment and install its packages (the user approves the download). Then run \
    the skill's code with `python` or `bash` and env set to the skill name. Skills that need nothing \
    beyond the standard library need no environment.
    """
    var inputSchema: JSON {
        Schema.object(["action": Schema.stringEnum("status (default) or setup", ["status", "setup"]),
                       "name": Schema.string("Skill name")], required: ["name"])
    }
    func effect(for input: JSON) -> ToolEffect { input.str("action") == "setup" ? .external : .readOnly }

    struct Failure: Error { let message: String }

    /// The interpreter for `env` in `python` / `bash`, or why it cannot be used yet.
    static func interpreter(_ skillName: String, _ ctx: ToolContext) -> Result<String, Failure> {
        guard let skill = ctx.services.skills.skill(skillName) else { return .failure(Failure(message: "No skill named \(skillName) (env must be a skill name).")) }
        let req = SkillEnvironments.requirements(of: skill)
        guard req.needsEnvironment else {
            return .failure(Failure(message: "Skill \(skillName) declares no packages, so it has no environment; run its code without env."))
        }
        guard let py = ctx.services.environments.interpreter(for: skill, req) else {
            return .failure(Failure(message: "The environment for \(skillName) is not set up. Call `skill_env` with action \"setup\" and name \"\(skillName)\" first (the user approves the download)."))
        }
        return .success(py)
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let n = try input.required("name")
        guard let skill = ctx.services.skills.skill(n) else { return .error("No skill named \(n).") }
        let envs = ctx.services.environments
        let req = SkillEnvironments.requirements(of: skill)
        if input.str("action") != "setup" {
            return ToolOutput(envs.describe(skill, secrets: ctx.services.secrets) ?? "Skill \(n) declares no Python requirements; it runs with the default python3.")
        }
        guard req.needsEnvironment else {
            return ToolOutput("Skill \(n) declares no packages, so no environment is needed. " + (envs.describe(skill, secrets: ctx.services.secrets) ?? ""))
        }
        ctx.services.emit(.notice(L10n.s("Setting up a Python environment for skill %@ (%@)…", n, req.packages.joined(separator: ", "))))
        do {
            let r = try await envs.setup(skill, req)
            ctx.services.log("skill_env_setup", actor: ctx.role.rawValue, ["skill": .string(n), "python": .string(r.python), "created": .bool(r.created),
                                                                           "packages": .array(req.packages.map { .string($0) }), "range": .string(req.python.spec)])
            let gaps = envs.gaps(req, secrets: ctx.services.secrets)
            return ToolOutput("""
            Environment for \(n) \(r.created ? "created" : "already present"): \(r.python)
            Installed: \(req.packages.joined(separator: ", "))
            Run the skill's code with `python` or `bash` and env "\(n)".\(gaps.isEmpty ? "" : "\nStill missing on this machine:\n" + gaps.map { "- " + $0 }.joined(separator: "\n"))
            """ + (r.created ? "\n\nInstall log (tail):\n" + String(r.log.suffix(1500)) : ""))
        } catch {
            ctx.services.log("skill_env_setup", actor: ctx.role.rawValue, ["skill": .string(n), "error": .string(error.localizedDescription.truncated(2000))])
            return .error("Could not set up the environment for \(n): \(error.localizedDescription)\nDo not work around this by installing into the user's own Python; report it.")
        }
    }
}
