// Error reporting to Sentry (#28). Kids use Foon, so events carry no personal data: scrubEvent is the last gate.
import * as Sentry from "@sentry/deno";

const DSN = "https://29ffc80ace3a4b5b9217ecb4ef86c9bd@o4510886326960128.ingest.us.sentry.io/4512447552880640";
const PRODUCTION_REF = "itnhdikhdsujklaimqqd";
const STAGING_REF = "cbftcssbnfdjjxoeflvj";
const EMAIL = /[^\s@<>"'()]+@[^\s@<>"'()]+\.[^\s@<>"'()]+/g;

export type SentryEnvironment = "production" | "staging";

// Local runs (kong, 127.0.0.1) and anything unknown report nothing.
export function sentryEnvironment(url: string | undefined): SentryEnvironment | null {
  if (url?.includes(PRODUCTION_REF)) return "production";
  if (url?.includes(STAGING_REF)) return "staging";
  return null;
}

const redact = (text: string | undefined) => text?.replace(EMAIL, "[email]");

export function scrubEvent<E extends Sentry.ErrorEvent>(event: E): E {
  const { request: _request, user: _user, extra: _extra, ...rest } = event;
  return {
    ...rest,
    message: redact(event.message),
    exception: event.exception && {
      ...event.exception,
      values: event.exception.values?.map((entry) => ({ ...entry, value: redact(entry.value) })),
    },
    breadcrumbs: event.breadcrumbs?.map((crumb) => ({ ...crumb, message: redact(crumb.message) })),
  } as E;
}

export interface ErrorReporter {
  capture(error: unknown, functionName: string): Promise<void>;
}

// Deno.serve has no per-request scope separation, so no default integrations; errors are captured by hand.
function sentryReporter(environment: SentryEnvironment, functionName: string): ErrorReporter {
  Sentry.init({
    dsn: DSN,
    environment,
    defaultIntegrations: false,
    // v11's replacement for sendDefaultPii: collect nothing about the request, the user, or local variables.
    dataCollection: {
      userInfo: false,
      cookies: false,
      httpHeaders: false,
      httpBodies: [],
      urlQueryParams: false,
      stackFrameVariables: false,
    },
    tracesSampleRate: 0,
    beforeSend: scrubEvent,
  });
  Sentry.setTag("function", functionName);
  Sentry.setTag("region", Deno.env.get("SB_REGION") ?? "unknown");
  return {
    async capture(error, name) {
      Sentry.withScope((scope) => {
        scope.setTag("function", name);
        Sentry.captureException(error);
      });
      await Sentry.flush(2000);
    },
  };
}

type Handler = (req: Request) => Response | Promise<Response>;

// `reporter` is injectable so tests never reach Sentry.
export function withSentry(
  name: string,
  handler: Handler,
  reporter: ErrorReporter | null = reporterFromEnv(name),
): Handler {
  if (!reporter) return handler;
  return async (req) => {
    try {
      return await handler(req);
    } catch (error) {
      await reporter.capture(error, name);
      return new Response("Internal Server Error", { status: 500 });
    }
  };
}

// Production reports start with privacy policy v3 (#356), which names Sentry; until then only staging reports.
export const REPORTING: readonly SentryEnvironment[] = ["staging"];

function reporterFromEnv(name: string): ErrorReporter | null {
  const environment = sentryEnvironment(Deno.env.get("SUPABASE_URL"));
  return environment && REPORTING.includes(environment) ? sentryReporter(environment, name) : null;
}
