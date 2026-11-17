import * as core from "@actions/core";
import { context } from "@actions/github";
import { parseOptions, loginPattern, repositoryPattern } from "./inputs";
import { GitHubClient } from "./github";
import { run } from "./run";
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

function targetFromPayload(): Target {
  const { pull_request: pull, issue, repository } = context.payload;
  const base = pull ? pull.base?.repo : repository;
  const owner = base?.owner?.login;
  const repo = base?.name;
  const pullNumber = (pull ?? issue)?.number;
  if (
    typeof owner !== "string" ||
    !loginPattern.test(owner) ||
    typeof repo !== "string" ||
    !repositoryPattern.test(repo) ||
    typeof pullNumber !== "number" ||
    !Number.isSafeInteger(pullNumber) ||
    pullNumber <= 0
  ) {
    throw new Error("A valid pull-request or issue event context is required");
  }
  return { owner, repo, pullNumber, kind: pull || issue?.pull_request ? "pull" : "issue" };
}

function commandRequested(command: string): boolean {
  if (context.eventName !== "issue_comment") return true;
  // Without a command, the action's own comment would retrigger it under a PAT or App token.
  if (!command) throw new Error("command is required for issue_comment events");
  const comment = context.payload.comment;
  return (
    context.payload.action === "created" &&
    trustedAssociations.includes(comment?.author_association) &&
    String(comment?.body ?? "")
      .split(/\r?\n/)
      .some((line) => line.trim() === command)
  );
}

function skip(reason: string): void {
  core.info(`Review roulette skipped: ${reason}`);
  core.setOutput("skipped", true);
}

export async function main(): Promise<void> {
  let token = "";
  try {
    token = core.getInput("token").trim();
    if (token) core.setSecret(token);
    const options = parseOptions({
      token,
      ...Object.fromEntries(inputNames.map((name) => [name, core.getInput(name)])),
    });
    if (!commandRequested(options.command))
      return skip("the comment is not the command from a repository collaborator");
    const target = targetFromPayload();
    const result = await run(options, target, new GitHubClient(token));
    const [first] = result.picks;
    if (!first) return skip("the required label is missing");
    core.setOutput("skipped", false);
    core.setOutput("reviewer", first.reviewer);
    core.setOutput("reviewers", [...new Set(result.picks.map((pick) => pick.reviewer))].join(","));
    core.setOutput("review-count", first.reviewCount);
    core.setOutput("issue-load", first.issueLoad ?? "");
    core.setOutput("workload", first.workload);
    core.setOutput("assigned", result.assigned);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Review roulette failed";
    core.setFailed(token ? message.replaceAll(token, "***") : message);
  }
}
