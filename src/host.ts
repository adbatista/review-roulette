import { actionsHost } from "./hosts/actions";
import { semaphoreHost } from "./hosts/semaphore";
import type { TargetKind } from "./model";

export interface HostEvent {
  target?: { owner: unknown; repo: unknown; number: unknown; kind: TargetKind };
  comment?: { created: boolean; association: unknown; body: unknown };
  skip?: string;
}

export interface Host {
  input(name: string): string;
  event(): HostEvent;
  secret(value: string): void;
  info(message: string): void;
  output(name: string, value: string | number | boolean): void;
  fail(message: string): void;
}

const hosts = { actions: actionsHost, semaphore: semaphoreHost };

export function detectHost(env: NodeJS.ProcessEnv = process.env): Host {
  const name =
    env.ROULETTE_HOST?.trim() || (env.GITHUB_ACTIONS === "true" ? "actions" : "semaphore");
  if (!Object.hasOwn(hosts, name))
    throw new Error(`ROULETTE_HOST must be one of: ${Object.keys(hosts).join(", ")}`);
  return hosts[name as keyof typeof hosts](env);
}
