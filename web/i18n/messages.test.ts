import { describe, expect, it } from "vitest";
import { locales } from "./config";
import { messagesFor } from "./messages";

// Every key path of a message tree, e.g. "common.retry".
function keys(tree: object, prefix = ""): string[] {
  return Object.entries(tree).flatMap(([key, value]) =>
    typeof value === "object" && value !== null ? keys(value, `${prefix}${key}.`) : [`${prefix}${key}`],
  );
}

describe("messages", () => {
  it("has one tree per locale with the same namespaces and keys", () => {
    const reference = keys(messagesFor("vi")).sort();
    expect(Object.keys(messagesFor("vi")).sort()).toEqual([
      "auth",
      "common",
      "errors",
      "feed",
      "profile",
      "share",
      "shell",
      "upload",
    ]);
    for (const locale of locales) {
      expect(keys(messagesFor(locale)).sort()).toEqual(reference);
    }
  });
});
