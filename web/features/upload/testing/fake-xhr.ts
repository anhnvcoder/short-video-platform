// A stand-in for XMLHttpRequest in unit tests (vi.stubGlobal("XMLHttpRequest", FakeXHR)): it records what the page
// would send to the storage, and the test decides when progress, the answer or a network failure comes.
export class FakeXHR {
  static instances: FakeXHR[] = [];

  readonly upload = new EventTarget();
  readonly headers: Record<string, string> = {};
  withCredentials = false;
  method: string | null = null;
  url: string | null = null;
  body: FormData | null = null;
  status = 0;
  aborted = false;
  private readonly events = new EventTarget();
  private responseHeaders: Record<string, string> = {};
  private finished = false;

  constructor() {
    FakeXHR.instances.push(this);
  }

  static reset() {
    FakeXHR.instances = [];
  }

  static last(): FakeXHR {
    const xhr = FakeXHR.instances.at(-1);
    if (!xhr) {
      throw new Error("no request was sent to the storage");
    }
    return xhr;
  }

  addEventListener(type: string, listener: EventListener) {
    this.events.addEventListener(type, listener);
  }

  open(method: string, url: string) {
    this.method = method;
    this.url = url;
  }

  setRequestHeader(name: string, value: string) {
    this.headers[name] = value;
  }

  send(body: FormData) {
    this.body = body;
  }

  abort() {
    if (this.finished) {
      return;
    }
    this.finished = true;
    this.aborted = true;
    this.events.dispatchEvent(new Event("abort"));
  }

  getResponseHeader(name: string): string | null {
    return this.responseHeaders[name.toLowerCase()] ?? null;
  }

  // Names of the form's fields in the order they were appended.
  fieldNames(): string[] {
    return [...(this.body?.keys() ?? [])];
  }

  progress(loaded: number, total: number) {
    this.upload.dispatchEvent(Object.assign(new Event("progress"), { loaded, total, lengthComputable: true }));
  }

  respond(status: number, headers: Record<string, string> = {}) {
    this.finished = true;
    this.status = status;
    this.responseHeaders = Object.fromEntries(
      Object.entries(headers).map(([key, value]) => [key.toLowerCase(), value]),
    );
    this.events.dispatchEvent(new Event("load"));
  }

  fail() {
    this.finished = true;
    this.events.dispatchEvent(new Event("error"));
  }
}
