import assert from "node:assert/strict";
import test from "node:test";

import { dialablePhone, offlineCompanionReply } from "../app/lib/asha-companion";

test("offline Asha never silently handles urgent language", () => {
  const reply = offlineCompanionReply("I cannot breathe");

  assert.equal(reply.urgent, true);
  assert.match(reply.reply, /Need help button/i);
  assert.doesNotMatch(reply.reply, /called|alert was sent/i);
});

test("phone handoff keeps only a bounded dialable number", () => {
  assert.equal(dialablePhone(" +880 (1712) 345-678 "), "+8801712345678");
  assert.equal(dialablePhone("not a number"), "");
  assert.equal(dialablePhone("123456789012345678901234"), "12345678901234567890");
});
