import { expect, it, vi } from "vite-plus/test";
vi.mock("../src/hosts/actions", () => ({ actionsHost: () => ({ name: "actions" }) }));
vi.mock("../src/hosts/semaphore", () => ({
  semaphoreHost: (env: unknown) => ({ name: "semaphore", env }),
}));
import { detectHost } from "../src/host";
it.each([
  [{ GITHUB_ACTIONS: "true" }, "actions"],
  [{ SEMAPHORE: "true" }, "semaphore"],
  [{}, "semaphore"],
  [{ GITHUB_ACTIONS: "true", ROULETTE_HOST: " semaphore " }, "semaphore"],
  [{ SEMAPHORE: "true", ROULETTE_HOST: "actions" }, "actions"],
])("selects the host for %j", (env, name) => {
  expect(detectHost(env)).toMatchObject({ name });
});
it("passes the environment to the selected host", () => {
  const env = { SEMAPHORE: "true" };
  expect(detectHost(env)).toMatchObject({ env });
});
it.each(["jenkins", "toString"])("rejects unknown host %s", (name) => {
  expect(() => detectHost({ ROULETTE_HOST: name })).toThrow(/actions, semaphore/);
});
