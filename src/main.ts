import { parseOptions, loginPattern, repositoryPattern } from "./inputs";
import { GitHubClient } from "./github";
import { run } from "./run";
import type { Host, HostEvent } from "./host";
import type { Target } from "./model";

const inputNames = [
  "reviewers",
  "organizations",
  "assign-reviewer",
  "issue-repositories",
  "status-field",
  "status-weights",
  "projects",
  "codeowners",
  "command",
  "required-label",
];
const trustedAssociations = ["OWNER", "MEMBER", "COLLABORATOR"];

function resolveTarget(event: HostEvent): Target {
  const { owner, repo, number, kind } = event.target ?? {};
  if (
    typeof owner !== "string" ||
    !loginPattern.test(owner) ||
    typeof repo !== "string" ||
    !repositoryPattern.test(repo) ||
    typeof number !== "number" ||
    !Number.isSafeInteger(number) ||
    number <= 0 ||
    !kind
  ) {
    throw new Error("A valid pull-request or issue event context is required");
  }
  return { owner, repo, pullNumber: number, kind };
}

function commandRequested(command: string, comment: HostEvent["comment"]): boolean {
  if (!comment) return true;
  // Without a command, the action's own comment would retrigger it under a PAT or App token.
  if (!command) throw new Error("command is required for issue_comment events");
  return (
    comment.created &&
    trustedAssociations.includes(String(comment.association)) &&
    typeof comment.body === "string" &&
    comment.body.split(/\r?\n/).some((line) => line.trim() === command)
  );
}

export async function main(host: Host): Promise<void> {
  let token = "";
  const skip = (reason: string) => {
    host.info(`Review roulette skipped: ${reason}`);
    host.output("skipped", true);
  };
  try {
    token = host.input("token").trim();
    if (token) host.secret(token);
    const options = parseOptions({
      token,
      ...Object.fromEntries(inputNames.map((name) => [name, host.input(name)])),
    });
    const event = host.event();
    if (event.skip) return skip(event.skip);
    if (!commandRequested(options.command, event.comment))
      return skip("the comment is not the command from a repository collaborator");
    const target = resolveTarget(event);
    const result = await run(options, target, new GitHubClient(token));
    const [first] = result.picks;
    if (!first) return skip("the required label is missing");
    host.output("skipped", false);
    host.output("reviewer", first.reviewer);
    host.output("reviewers", [...new Set(result.picks.map((pick) => pick.reviewer))].join(","));
    host.output("review-count", first.reviewCount);
    host.output("issue-load", first.issueLoad ?? "");
    host.output("workload", first.workload);
    host.output("assigned", result.assigned);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Review roulette failed";
    host.fail(token ? message.replaceAll(token, "***") : message);
  }
}
