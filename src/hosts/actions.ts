import * as core from "@actions/core";
import { context } from "@actions/github";
import type { Host } from "../host";

export function actionsHost(): Host {
  return {
    input: (name) => core.getInput(name),
    event() {
      const { pull_request: pull, issue, repository, comment, action } = context.payload;
      const base = pull ? pull.base?.repo : repository;
      return {
        target: {
          owner: base?.owner?.login,
          repo: base?.name,
          number: (pull ?? issue)?.number,
          kind: pull || issue?.pull_request ? "pull" : "issue",
        },
        ...(context.eventName === "issue_comment"
          ? {
              comment: {
                created: action === "created",
                association: comment?.author_association,
                body: comment?.body,
              },
            }
          : {}),
      };
    },
    secret: (value) => core.setSecret(value),
    info: (message) => core.info(message),
    output: (name, value) => core.setOutput(name, value),
    fail: (message) => core.setFailed(message),
  };
}
