import { describe, expect, it } from "vitest";
import { beats, foundingOffer, screenshots, SUPPORT_EMAIL } from "../app/content";
import { submitWaitlist, waitlistSchema } from "../app/utils/waitlist";

const reply = (status: number) => (() => Promise.resolve(new Response("{}", { status }))) as unknown as typeof fetch;

describe("waitlistSchema", () => {
  it("trims and accepts a real email with an optional name", () => {
    expect(waitlistSchema.parse({ email: " pat@example.com ", firstName: " Pat " })).toEqual({
      email: "pat@example.com",
      firstName: "Pat",
    });
    expect(waitlistSchema.safeParse({ email: "pat@example.com" }).success).toBe(true);
  });

  it("rejects what isn't an email or is too long", () => {
    expect(waitlistSchema.safeParse({ email: "pat" }).success).toBe(false);
    expect(waitlistSchema.safeParse({ email: "" }).success).toBe(false);
    expect(waitlistSchema.safeParse({ email: "a@example.com", firstName: "x".repeat(41) }).success).toBe(false);
  });

  it("only lets a first name be a name", () => {
    for (const firstName of ["Zoë", "Mary-Jane", "O'Brien", "李雷", ""]) {
      expect(waitlistSchema.safeParse({ email: "a@example.com", firstName }).success).toBe(true);
    }
    for (const firstName of ["Pat http://evil.example", "<b>Pat", "Pat1", "-Pat"]) {
      expect(waitlistSchema.safeParse({ email: "a@example.com", firstName }).success).toBe(false);
    }
  });
});

describe("submitWaitlist", () => {
  const input = { email: "pat@example.com", firstName: "", website: "" };

  it("posts the trimmed values with the honeypot field", async () => {
    let body: unknown;
    const spy = ((_: string, init: RequestInit) => {
      body = JSON.parse(init.body as string);
      return Promise.resolve(new Response("{}", { status: 200 }));
    }) as unknown as typeof fetch;
    expect(await submitWaitlist("https://f/waitlist", input, spy)).toBe("ok");
    expect(body).toEqual({ email: "pat@example.com", firstName: "", website: "" });
  });

  it("never calls out for a bad email", async () => {
    expect(await submitWaitlist("https://f/waitlist", { email: "nope" }, reply(200))).toBe("invalid");
  });

  it("says unavailable with no endpoint configured", async () => {
    expect(await submitWaitlist("", input, reply(200))).toBe("unavailable");
  });

  it("maps the function's answers", async () => {
    expect(await submitWaitlist("https://f", input, reply(400))).toBe("invalid");
    expect(await submitWaitlist("https://f", input, reply(429))).toBe("slow_down");
    expect(await submitWaitlist("https://f", input, reply(500))).toBe("error");
    const offline = (() => Promise.reject(new TypeError("offline"))) as unknown as typeof fetch;
    expect(await submitWaitlist("https://f", input, offline)).toBe("error");
  });
});

describe("content", () => {
  it("quotes the founding price from the spec", () => {
    expect(foundingOffer.points.join(" ")).toContain("$24.99");
    expect(foundingOffer.points.join(" ")).toContain("$49.99");
    expect(foundingOffer.fineprint).toContain("50 families");
  });

  it("has four beats and screenshot slots with alt text", () => {
    expect(beats).toHaveLength(4);
    for (const shot of screenshots) expect(shot.alt.length).toBeGreaterThan(10);
  });

  it("keeps nutrition talk out of the copy", () => {
    const copy = JSON.stringify({ beats, foundingOffer }).toLowerCase();
    for (const word of ["calorie", "nutrition", "diet", "macro"]) expect(copy).not.toContain(word);
  });

  it("has one support address", () => {
    expect(SUPPORT_EMAIL).toBe("support@getfoon.com");
  });
});
