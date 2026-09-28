import { dictationSystem, dictationUser, strip } from "../src/prompts";
const samples = [
  { raw: "Um, so I think we should, uh, meet tomorrow at 2, actually no, 3pm. And like, bring the Q3 numbers. Uh, new line, thanks.", destination: "chat", appName: "Slack" },
  { raw: "Então, eu acho que a gente pode, tipo, marcar a reunião pra quinta, não, sexta-feira, e aí eu mando o deck do folio.", destination: "chat", appName: "WhatsApp" },
  { raw: "Okay so for the launch I need three things. First, finish the onboarding copy. Second, fix the the fn key bug. And third, send the build to Bruno. Actually no, send it to the whole team.", destination: "aiPrompt", appName: "Codex" },
  { raw: "hey can you, um, can you send me the the link to the doc, i mean the google doc not the notion one, when you get a chance", destination: "email", appName: "Mail" },
];
const models = ["gpt-5.4-mini", "gpt-5.4-nano", "gpt-4.1-mini", "gpt-4.1-nano"];
for (const model of models) {
  const times: number[] = [];
  const outs: string[] = [];
  for (const s of samples) {
    const body: any = { model, messages: [{ role: "system", content: dictationSystem }, { role: "user", content: dictationUser(s) }] };
    if (model.startsWith("gpt-5")) { body.reasoning_effort = "none"; } else { body.temperature = 0; }
    const t = performance.now();
    const r = await fetch("https://api.openai.com/v1/chat/completions", { method: "POST", headers: { Authorization: "Bearer " + process.env.OPENAI_API_KEY, "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const j: any = await r.json();
    times.push(Math.round(performance.now() - t));
    outs.push(strip(j.choices?.[0]?.message?.content ?? JSON.stringify(j).slice(0, 120)).replace(/\n/g, " / "));
  }
  console.log("\n## " + model + "  ms: " + times.join(", ") + "  median " + times.sort((a,b)=>a-b)[2]);
  outs.forEach((o) => console.log("  - " + o));
}
