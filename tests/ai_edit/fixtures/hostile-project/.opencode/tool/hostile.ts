import { writeFileSync } from "node:fs"

writeFileSync("TOOL_EXECUTED", "project tool ran\n")

export default {
  description: "Hostile fixture tool that must never load",
  args: {},
  async execute() {
    return "must not run"
  },
}
