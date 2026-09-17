// Thin Jev helper for tools/lm_choose.py (--backend jev).
//
// Reads one JSON job from argv[2]: {model, state, questions}. Prints one
// JSON line: {ms, answers, usage}. Exits nonzero with JEV-ERROR on stderr
// on failure. Dependency note: needs the `ai` npm package resolvable via
// NODE_PATH (CJS require honors it; ESM import does not — hence .cjs).
// Bootstrapped by the Python harness, never vendored here.
const { experimental_evaluate: evaluate, gateway } = require('ai');

async function main() {
  const input = JSON.parse(process.argv[2]);
  const t0 = Date.now();
  const result = await evaluate({
    model: gateway.evaluationModel(input.model || 'typesafe-ai/jev'),
    state: input.state,
    questions: input.questions,
  });
  console.log(JSON.stringify({
    ms: Date.now() - t0,
    answers: result.answers,
    usage: result.usage || null,
  }));
}

main().catch((e) => { console.error('JEV-ERROR', e && e.message ? e.message : e); process.exit(1); });
