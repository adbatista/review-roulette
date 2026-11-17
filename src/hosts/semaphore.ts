import { appendFileSync, readFileSync } from "node:fs";
import type { Host } from "../host";

const variable = (name: string) => `ROULETTE_${name.toUpperCase().replaceAll("-", "_")}`;

function stringify(value: unknown): string {
  if (Array.isArray(value)) return value.map(String).join("\n");
  if (value && typeof value === "object")
    return Object.entries(value)
      .map(([key, entry]) => `${key}: ${entry}`)
      .join("\n");
  return ["string", "number", "boolean"].includes(typeof value) ? `${value as string}` : "";
}

// Driven only by environment variables and an optional JSON file, so it also runs on
// any other CI once ROULETTE_REPOSITORY and ROULETTE_NUMBER are set.
export function semaphoreHost(env: NodeJS.ProcessEnv = process.env): Host {
  let config: Record<string, unknown> | undefined;
  const loadConfig = () => {
    if (config) return config;
    const path = env.ROULETTE_CONFIG?.trim();
    const parsed: unknown = path ? JSON.parse(readFileSync(path, "utf8")) : {};
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
      throw new Error("ROULETTE_CONFIG must point to a JSON object");
    return (config = parsed as Record<string, unknown>);
  };
  const info = (message: string) => console.log(message);
  return {
    input(name) {
      const value = env[variable(name)];
      if (value !== undefined) return value;
      if (name === "token") return env.GITHUB_TOKEN ?? "";
      return stringify(loadConfig()[name]);
    },
    event() {
      if (env.SEMAPHORE_GIT_PROVIDER && env.SEMAPHORE_GIT_PROVIDER !== "github")
        throw new Error("Review roulette only supports repositories hosted on GitHub");
      // SEMAPHORE_GIT_REPO_SLUG is the project's repository, never the fork a PR came from.
      const [owner, repo, ...rest] = (
        env.ROULETTE_REPOSITORY ??
        env.SEMAPHORE_GIT_REPO_SLUG ??
        ""
      ).split("/");
      const number = (env.ROULETTE_NUMBER ?? env.SEMAPHORE_GIT_PR_NUMBER ?? "").trim();
      const kind = env.ROULETTE_KIND?.trim() || "pull";
      if (kind !== "pull" && kind !== "issue")
        throw new Error("ROULETTE_KIND must be pull or issue");
      if (!number) return { skip: "this is not a pull-request build and ROULETTE_NUMBER is unset" };
      return {
        target: {
          owner,
          repo: rest.length ? undefined : repo,
          number: /^\d+$/.test(number) ? Number(number) : undefined,
          kind,
        },
      };
    },
    secret() {},
    info,
    output(name, value) {
      const line = `${variable(name)}=${value}`;
      info(line);
      const path = env.ROULETTE_OUTPUT_FILE?.trim();
      if (path) appendFileSync(path, line + "\n");
    },
    fail(message) {
      console.error(`Review roulette failed: ${message}`);
      process.exitCode = 1;
    },
  };
}
