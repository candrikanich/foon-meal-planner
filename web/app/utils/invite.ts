// The page an invite link opens when Foon isn't installed (#85). The code arrives as ?code=, and a link someone typed
// or a mail app mangled can carry anything, so only something shaped like a code is shown.

const CODE = /^[A-Z0-9]+(?:-[A-Z0-9]+){0,3}$/;
const MAX_LENGTH = 20;

export function inviteCode(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const code = value.trim().toUpperCase();
  return code.length <= MAX_LENGTH && CODE.test(code) ? code : null;
}
