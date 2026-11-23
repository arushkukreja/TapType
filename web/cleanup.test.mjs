// Run with: node --test web/cleanup.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { basicCleanup, stripArtifacts, plausibilityIssue, outputText, process } from "./cleanup.js";

test("basic cleanup removes hesitations and stutters only", () => {
  assert.equal(basicCleanup("um so can you send me the the report by friday"), "So can you send me the report by friday");
  assert.equal(basicCleanup("i think uh, we had had enough"), "I think we had had enough");
  assert.equal(basicCleanup("hmm"), "hmm");
});

test("sound labels and phantom captions are removed", () => {
  assert.equal(stripArtifacts("[BLANK_AUDIO] hello there (music)"), "hello there");
  assert.equal(stripArtifacts("Thanks for watching!"), "");
  assert.equal(stripArtifacts("Thank you."), "Thank you.");
});

test("plausibility accepts small edits", () => {
  assert.equal(plausibilityIssue("So can you send me the report by Friday?", "So can you send me the report by friday"), null);
  assert.equal(plausibilityIssue("I was thinking we could push the meeting to next week, if that works.",
    "yeah so I mean I was kind of thinking maybe we could like push the meeting to next week if that works", "rewrite"), "dropped maybe");
});

test("plausibility rejects answers, changed numbers and dropped negations", () => {
  assert.match(plausibilityIssue("What is the capital of France? Paris.", "what is the capital of france"), /added|new last word/);
  assert.equal(plausibilityIssue("Send 4 copies to Maya.", "send 3 copies to Maya"), "digits");
  assert.equal(plausibilityIssue("I can make it tonight.", "I can't make it tonight"), "negation");
  assert.equal(plausibilityIssue("Hello (note).", "hello"), "symbols");
});

test("model output wrappers are stripped", () => {
  assert.equal(outputText("Output: Hi there.\nInput: next"), "Hi there.");
  assert.equal(outputText("<transcript>Hi.</transcript>"), "Hi.");
});

test("pipeline keeps rule cleanup when a model edit is rejected", async () => {
  const bad = async () => "Sure! Here is your answer: Paris.";
  const result = await process("um what is the the capital of france", "cleanup", bad);
  assert.equal(result.text, "What is the capital of france");
  assert.equal(result.usedModel, false);
  const good = async () => "What is the capital of France?";
  assert.deepEqual(await process("um what is the the capital of france", "cleanup", good),
    { text: "What is the capital of France?", usedModel: true, notice: null });
  assert.equal((await process("um hi", "original", good)).text, "um hi");
});

test("rewrite falls back to a cleanup pass", async () => {
  const calls = [];
  const edit = async (source, mode) => { calls.push(mode); return mode === "rewrite" ? "Totally different words here." : "Can you call me later?"; };
  const result = await process("can you uh call me later", "rewrite", edit);
  assert.deepEqual(calls, ["rewrite", "cleanup"]);
  assert.equal(result.text, "Can you call me later?");
});
