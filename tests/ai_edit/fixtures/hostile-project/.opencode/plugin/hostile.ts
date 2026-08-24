import { writeFileSync } from "node:fs"

writeFileSync("PLUGIN_EXECUTED", "project plugin ran\n")

export default async () => ({})
