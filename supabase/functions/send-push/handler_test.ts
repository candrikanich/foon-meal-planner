import { assertEquals } from "@std/assert";
import type { ApnsPayload, DeliveryResult, Device } from "./apns.ts";
import { handleSendPush, type OutboxRow, type SendPushDeps } from "./handler.ts";

const sandbox: Device = { token: "ab".repeat(32), environment: "sandbox" };
const production: Device = { token: "cd".repeat(32), environment: "production" };

function fakeDeps(
  rows: OutboxRow[],
  results: Record<string, DeliveryResult> = {},
  overrides: Partial<SendPushDeps> = {},
): { deps: SendPushDeps; steps: string[] } {
  const steps: string[] = [];
  let claimed = false;
  const deps: SendPushDeps = {
    cronSecret: "s3cret",
    providerToken: () => Promise.resolve("jwt"),
    claim: () => {
      const batch = claimed ? [] : rows;
      claimed = true;
      return Promise.resolve(batch);
    },
    deliver: (device) => {
      steps.push(`deliver ${device.environment}`);
      return Promise.resolve(results[device.token] ?? "delivered");
    },
    forgetDevices: (tokens) => {
      steps.push(`forget ${tokens.length}`);
      return Promise.resolve();
    },
    complete: (id, outcome) => {
      steps.push(`complete ${id} ${outcome}`);
      return Promise.resolve();
    },
    log: () => {},
    ...overrides,
  };
  return { deps, steps };
}

const request = (secret: string | null = "s3cret") =>
  new Request("http://localhost/send-push", {
    method: "POST",
    headers: secret ? { "x-push-secret": secret } : {},
    body: "{}",
  });

const row = (devices: Device[], kind = "plan_set"): OutboxRow => ({
  id: "row-1",
  kind,
  week_start: "2026-11-01",
  night_id: null,
  night_date: null,
  args: {},
  attempts: 1,
  devices,
});

Deno.test("without the cron secret nothing is claimed", async () => {
  const { deps, steps } = fakeDeps([row([sandbox])]);
  assertEquals((await handleSendPush(request(null), deps)).status, 401);
  assertEquals((await handleSendPush(request("wrong"), deps)).status, 401);
  assertEquals((await handleSendPush(request("s3cret"), { ...deps, cronSecret: undefined })).status, 401);
  assertEquals(steps, []);
});

Deno.test("without the Apple secrets nothing is claimed", async () => {
  const { deps, steps } = fakeDeps([row([sandbox])], {}, { providerToken: null });
  assertEquals((await handleSendPush(request(), deps)).status, 500);
  assertEquals(steps, []);
});

Deno.test("a push one device took is marked sent, which logs it", async () => {
  const { deps, steps } = fakeDeps([row([sandbox, production])], { [sandbox.token]: "retry" });
  const response = await handleSendPush(request(), deps);
  assertEquals(response.status, 200);
  assertEquals((await response.json()).sent, 1);
  assertEquals(steps, ["deliver sandbox", "deliver production", "complete row-1 sent"]);
});

Deno.test("a dead token is forgotten, and with no device left the row fails", async () => {
  const { deps, steps } = fakeDeps([row([sandbox])], { [sandbox.token]: "dead_token" });
  await handleSendPush(request(), deps);
  assertEquals(steps, ["deliver sandbox", "forget 1", "complete row-1 no_devices"]);
});

Deno.test("a dead token beside a delivered one is forgotten and the row still sent", async () => {
  const { deps, steps } = fakeDeps([row([sandbox, production])], { [sandbox.token]: "dead_token" });
  await handleSendPush(request(), deps);
  assertEquals(steps, ["deliver sandbox", "deliver production", "forget 1", "complete row-1 sent"]);
});

Deno.test("nothing delivered and nothing dead is retried", async () => {
  const { deps, steps } = fakeDeps([row([sandbox])], { [sandbox.token]: "retry" });
  await handleSendPush(request(), deps);
  assertEquals(steps, ["deliver sandbox", "complete row-1 retry"]);
});

Deno.test("a kind this sender doesn't know, or a person with no device, fails without a post", async () => {
  const unknown = fakeDeps([row([sandbox], "something_new")]);
  await handleSendPush(request(), unknown.deps);
  assertEquals(unknown.steps, ["complete row-1 unknown_kind"]);
  const deviceless = fakeDeps([row([])]);
  await handleSendPush(request(), deviceless.deps);
  assertEquals(deviceless.steps, ["complete row-1 no_devices"]);
});

Deno.test("a push about a night opens that night, with the name from args", async () => {
  const payloads: ApnsPayload[] = [];
  const claim: OutboxRow = {
    ...row([sandbox], "claim"),
    week_start: null,
    night_id: "night-1",
    night_date: "2026-11-05",
    args: { name: "Ben" },
  };
  const { deps, steps } = fakeDeps([claim], {}, {
    deliver: (_device, payload) => {
      payloads.push(payload);
      return Promise.resolve("delivered");
    },
  });
  await handleSendPush(request(), deps);
  assertEquals(payloads, [{
    aps: { alert: { title: "Ben will cook Thursday.", body: "Tap to see the night." }, sound: "default" },
    route: "night",
    night: "night-1",
    date: "2026-11-05",
  }]);
  assertEquals(steps, ["complete row-1 sent"]);
});

Deno.test("an urgent item opens the list, though it carries tonight's night", async () => {
  const payloads: ApnsPayload[] = [];
  const urgent: OutboxRow = {
    ...row([sandbox], "urgent_item"),
    week_start: null,
    night_id: "night-1",
    night_date: "2026-11-05",
    args: { name: "Ben" },
  };
  const { deps } = fakeDeps([urgent], {}, {
    deliver: (_device, payload) => {
      payloads.push(payload);
      return Promise.resolve("delivered");
    },
  });
  await handleSendPush(request(), deps);
  assertEquals(payloads, [{
    aps: { alert: { title: "Ben added something for tonight.", body: "Tap to see the list." }, sound: "default" },
    route: "list",
  }]);
});

Deno.test("a tonight poll opens This Week, where the vote card is", async () => {
  const payloads: ApnsPayload[] = [];
  const poll: OutboxRow = {
    ...row([sandbox], "tonight_poll"),
    week_start: null,
    night_id: "night-1",
    night_date: "2026-11-05",
    args: { name: "Ben" },
  };
  const { deps } = fakeDeps([poll], {}, {
    deliver: (_device, payload) => {
      payloads.push(payload);
      return Promise.resolve("delivered");
    },
  });
  await handleSendPush(request(), deps);
  assertEquals(payloads, [{
    aps: { alert: { title: "Ben started a vote on dinner.", body: "Tap to vote." }, sound: "default" },
    route: "dinner",
  }]);
});

Deno.test("the ideas digest opens Ideas", async () => {
  const payloads: ApnsPayload[] = [];
  const digest: OutboxRow = { ...row([sandbox], "new_requests"), week_start: null, args: { count: 3 } };
  const { deps } = fakeDeps([digest], {}, {
    deliver: (_device, payload) => {
      payloads.push(payload);
      return Promise.resolve("delivered");
    },
  });
  await handleSendPush(request(), deps);
  assertEquals(payloads, [{
    aps: { alert: { title: "3 new dinner ideas.", body: "Tap to see them." }, sound: "default" },
    route: "ideas",
  }]);
});

Deno.test("a store run opens the list", async () => {
  const payloads: ApnsPayload[] = [];
  const run: OutboxRow = { ...row([sandbox], "heading_to_store"), week_start: null, args: { name: "Ben" } };
  const { deps } = fakeDeps([run], {}, {
    deliver: (_device, payload) => {
      payloads.push(payload);
      return Promise.resolve("delivered");
    },
  });
  await handleSendPush(request(), deps);
  assertEquals(payloads, [{
    aps: { alert: { title: "Ben's at the store.", body: "Add anything in the next 10 minutes." }, sound: "default" },
    route: "list",
  }]);
});

Deno.test("a push with no name says Someone", async () => {
  const payloads: ApnsPayload[] = [];
  const nameless: OutboxRow = { ...row([sandbox], "not_home"), week_start: null, night_id: "night-1",
    night_date: "2026-11-05", args: null };
  const { deps, steps } = fakeDeps([nameless], {}, {
    deliver: (_device, payload) => {
      payloads.push(payload);
      return Promise.resolve("delivered");
    },
  });
  await handleSendPush(request(), deps);
  assertEquals(payloads[0].aps.alert.title, "Someone won't be home tonight.");
  assertEquals(steps, ["complete row-1 sent"]);
});

Deno.test("a push whose words can't be made fails without a post", async () => {
  const countless = fakeDeps([{ ...row([sandbox], "new_requests"), args: null }]);
  await handleSendPush(request(), countless.deps);
  assertEquals(countless.steps, ["complete row-1 no_words"]);
  const dateless = fakeDeps([{ ...row([sandbox], "claim"), args: { name: "Ben" }, night_date: null }]);
  const response = await handleSendPush(request(), dateless.deps);
  assertEquals(dateless.steps, ["complete row-1 no_words"]);
  assertEquals((await response.json()).no_words, 1);
});

Deno.test("a database error stops the run and says so", async () => {
  const { deps } = fakeDeps([], {}, { claim: () => Promise.reject(new Error("db down")) });
  assertEquals((await handleSendPush(request(), deps)).status, 500);
});

Deno.test("only POST", async () => {
  const { deps } = fakeDeps([]);
  assertEquals((await handleSendPush(new Request("http://localhost/send-push"), deps)).status, 405);
});
