import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const destination = resolve(root, "web/src/abi");
const contracts = ["AuctionFactory", "DutchAuction", "AuctionToken"];

await mkdir(destination, { recursive: true });

for (const name of contracts) {
  const artifact = JSON.parse(
    await readFile(resolve(root, "out", `${name}.sol`, `${name}.json`), "utf8"),
  );
  await writeFile(
    resolve(destination, `${name}.json`),
    JSON.stringify(artifact.abi, null, 2) + "\n",
  );
}

process.stdout.write(`Exported ${contracts.join(", ")} ABIs to web/src/abi\n`);
